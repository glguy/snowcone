#include "httpd.hpp"
#include "LuaRef.hpp"
#include "app.hpp"
#include "safecall.hpp"
#include "strings.hpp"
#include "userdata.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <algorithm>
#include <boost/asio/dispatch.hpp>
#include <boost/asio/strand.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>
#include <boost/beast/websocket.hpp>
#include <boost/config.hpp>
#include <cstdlib>
#include <queue>
#include <functional>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>


namespace beast = boost::beast; // from <boost/beast.hpp>
namespace http = beast::http; // from <boost/beast/http.hpp>
namespace net = boost::asio; // from <boost/asio.hpp>
namespace websocket = beast::websocket;
using tcp = net::ip::tcp; // from <boost/asio/ip/tcp.hpp>
using namespace std::literals;

namespace {

class Websocket : public std::enable_shared_from_this<Websocket>
{
    // Note that this class uses a shared_ptr because the stream
    // destructor for stream specifically must not run while
    // asynchronous operations are in flight.

    websocket::stream<beast::tcp_stream> ws_;
    std::queue<std::string> messages_; // outgoing messages
    beast::flat_buffer buffer_; // incoming message
    LuaRef cb_; // on_recv callback
    bool closed;

public:
    Websocket(beast::tcp_stream&& stream)
        : ws_{std::move(stream)}
        , cb_{}
        , closed{false}
    {
        ws_.set_option(websocket::stream_base::timeout::suggested(beast::role_type::server));
    }

    auto set_callback(LuaRef ref) -> void
    {
        cb_ = std::move(ref);
    }

    auto close() -> void
    {
        if (not closed)
        {
            closed = true;
            if (messages_.empty())
            {
                start_close();
            }
        }
    }

    auto send(std::string str) -> void
    {
        if (not closed)
        {
            messages_.push(std::move(str));
            if (1 == messages_.size())
            {
                start_write();
            }
        }
    }

    template <typename Body, typename Allocator>
    auto run(http::request<Body, http::basic_fields<Allocator>> const& req) -> void
    {
        ws_.async_accept(req, beast::bind_front_handler(&Websocket::on_accept, shared_from_this()));
    }

private:
    auto on_accept(boost::system::error_code const ec) -> void
    {
        start_read();
        if (not messages_.empty())
        {
            start_write();
        }
    }

    auto start_write() -> void
    {
        ws_.async_write(
            net::buffer(messages_.front()),
            beast::bind_front_handler(&Websocket::on_write, shared_from_this())
        );
    }

    auto on_write(boost::system::error_code const ec, std::size_t) -> void
    {
        if (ec)
        {
            closed = true;
            messages_ = {};
        }
        else
        {
            messages_.pop();
            if (not messages_.empty())
            {
                start_write();
            }
            else if (closed)
            {
                start_close();
            }
        }
    }

    auto start_read() -> void
    {
        buffer_.clear();
        ws_.async_read(
            buffer_,
            beast::bind_front_handler(&Websocket::on_read, shared_from_this())
        );
    }

    auto on_read(boost::system::error_code const ec, std::size_t const) -> void
    {
        if (ec)
        {
            if (cb_)
            {
                auto const L = cb_.get_lua();
                cb_.push();
                luaL_pushfail(L);
                push_string(L, ec.what());
                safecall(L, "wsreaderr", 2);
            }
        }
        else
        {
            if (cb_)
            {
                auto const L = cb_.get_lua();
                cb_.push();
                auto const buf = buffer_.data();
                lua_pushlstring(L, static_cast<char*>(buf.data()), buf.size());
                safecall(L, "wsread", 1);
            }
            start_read();
        }
    }

    auto start_close() -> void
    {
        ws_.async_close(
            websocket::close_code::normal,
            beast::bind_front_handler(&Websocket::on_close, shared_from_this())
        );
    }

    auto on_close(boost::system::error_code) -> void
    {
    }
};

luaL_Reg const WsMT[]{
    {"__gc", [](auto const L) {
         std::destroy_at(check_udata<std::shared_ptr<Websocket>>(L, 1));
         return 0;
     }},
    {}
};

luaL_Reg const WsM[]{
    {"send", [](auto const L) {
         auto& w = *check_udata<std::shared_ptr<Websocket>>(L, 1);
         auto const s = check_string_view(L, 2);
         w->send(std::string{s});
         return 0;
     }},
    {"close", [](auto const L) {
         auto& w = *check_udata<std::shared_ptr<Websocket>>(L, 1);
         w->close();
         return 0;
     }},
    {"on_recv", [](auto const L) {
         auto& w = *check_udata<std::shared_ptr<Websocket>>(L, 1);
         lua_settop(L, 2);
         w->set_callback(LuaRef::create(L));
         return 0;
     }},
    {}
};

template <class Body, class Allocator>
auto handle_websocket(
    LuaRef const& cb,
    beast::tcp_stream&& stream,
    http::request<Body, http::basic_fields<Allocator>> const& req
) -> void
{
    stream.expires_never();

    auto const L = cb.get_lua();
    cb.push();
    lua_pushstring(L, "WS");
    push_string(L, req.target());
    auto& obj = *new_udata<std::shared_ptr<Websocket>>(L, 0, [L] {
        luaL_setfuncs(L, WsMT, 0);
        luaL_newlibtable(L, WsM);
        luaL_setfuncs(L, WsM, 0);
        lua_setfield(L, -2, "__index");
    });
    std::construct_at(
        &obj,
        std::make_shared<Websocket>(std::move(stream))
    );
    obj->run(req);

    safecall(L, "ws", 3);
}

// Return a response for the given request.
//
// The concrete type of the response message (which depends on the
// request), is type-erased in message_generator.
template <class Body, class Allocator>
auto handle_request(
    LuaRef const& cb,
    http::request<Body, http::basic_fields<Allocator>>&& req
) -> http::message_generator
{
    // Returns a server error response
    auto const server_error =
        [&req](std::string_view what) {
            http::response<http::string_body> res{http::status::internal_server_error, req.version()};
            res.set(http::field::server, BOOST_BEAST_VERSION_STRING);
            res.set(http::field::content_type, "text/plain");
            res.keep_alive(req.keep_alive());
            res.body() = what;
            res.prepare_payload();
            return res;
        };

    auto const L = cb.get_lua();
    cb.push();
    push_string(L, req.method_string());
    push_string(L, req.target());
    push_string(L, req.body());

    lua_newtable(L);
    for (auto&& field : req) {
        push_string(L, field.name_string());
        push_string(L, field.value());
        lua_settable(L, -3);
    }

    if (LUA_OK != lua_pcall(L, 4, 3, 0))
    {
        std::string const err = lua_tostring(L, -1);
        lua_pop(L, 1);
        return server_error(err);
    }

    auto const code = lua_tointeger(L, -3);
    if (code == 0)
    {
        lua_pop(L, 3);
        return server_error("internal server error"sv);
    }

    http::response<http::string_body> res{http::int_to_status(code), req.version()};
    res.set(http::field::server, BOOST_BEAST_VERSION_STRING);
    res.keep_alive(req.keep_alive());

    std::size_t len;
    auto const body_ptr = lua_tolstring(L, -2, &len);
    if (body_ptr == nullptr)
    {
        res.content_length(0);
    }
    else
    {
        res.content_length(len);
        res.body() = {body_ptr, len};
    }

    if (lua_type(L, -1) == LUA_TTABLE)
    {
        lua_pushnil(L);
        while (0 != lua_next(L, -2)) {
            auto const key = luaL_tolstring(L, -2, nullptr);
            auto const val = lua_tostring(L, -2);
            if (key == nullptr || val == nullptr)
            {
                lua_pop(L, 6);
                return server_error("internal server error");
            }
            res.set(key, val);
            lua_pop(L, 2); // remove value and key-copy
        }
    }

    lua_pop(L, 3);

    return res;
}

//------------------------------------------------------------------------------

void fail(LuaRef const& cb, beast::error_code const ec, char const* const what)
{
    auto const L = cb.get_lua();
    cb.push();
    luaL_pushfail(L);
    lua_pushstring(L, what);
    push_string(L, ec.message());
    safecall(L, "httpd error", 3);
}

class Session : public std::enable_shared_from_this<Session>
{
    beast::tcp_stream stream_;
    beast::flat_buffer buffer_;
    LuaRef cb_;
    http::request<http::string_body> req_;

public:
    Session(tcp::socket&& socket, LuaRef&& cb)
        : stream_{std::move(socket)}
        , cb_{std::move(cb)}
    {
    }

    auto run() -> void
    {
        // We need to be executing within a strand to perform async operations
        // on the I/O objects in this session. Although not strictly necessary
        // for single-threaded contexts, this example code is written to be
        // thread-safe by default.
        net::dispatch(stream_.get_executor(), beast::bind_front_handler(&Session::do_read, shared_from_this()));
    }

    auto do_read() -> void
    {
        req_.clear();
        stream_.expires_after(30s);
        http::async_read(stream_, buffer_, req_, beast::bind_front_handler(&Session::on_read, shared_from_this()));
    }

    auto on_read(
        beast::error_code const ec,
        std::size_t
    ) -> void
    {
        // This means they closed the connection
        if (ec == http::error::end_of_stream)
        {
            return do_close();
        }

        if (ec)
        {
            return fail(cb_, ec, "read");
        }

        if (websocket::is_upgrade(req_))
        {
            handle_websocket(std::move(cb_), std::move(stream_), std::move(req_));
        }
        else
        {
            send_response(handle_request(cb_, std::move(req_)));
        }
    }

    auto send_response(http::message_generator&& msg) -> void
    {
        auto const keep_alive = msg.keep_alive();

        // Write the response
        beast::async_write(
            stream_,
            std::move(msg),
            beast::bind_front_handler(
                &Session::on_write, shared_from_this(), keep_alive
            )
        );
    }

    auto on_write(
        bool const keep_alive,
        beast::error_code const ec,
        std::size_t
    ) -> void
    {
        if (ec)
        {
            return fail(cb_, ec, "write");
        }

        if (!keep_alive)
        {
            // This means we should close the connection, usually because
            // the response indicated the "Connection: close" semantic.
            return do_close();
        }

        do_read();
    }

    auto do_close() -> void
    {
        beast::error_code ec;
        stream_.socket().shutdown(tcp::socket::shutdown_send, ec);
    }
};

//------------------------------------------------------------------------------

// Accepts incoming connections and launches the sessions
class Listener : public std::enable_shared_from_this<Listener>
{
    net::io_context& ioc_;
    std::vector<tcp::acceptor> acceptors_;
    tcp::resolver resolver_;
    LuaRef const cb_;

public:
    Listener(
        net::io_context& ioc,
        LuaRef&& cb
    )
        : ioc_{ioc}
        , acceptors_{}
        , resolver_{ioc}
        , cb_{std::move(cb)}
    {
    }

    auto on_resolve(beast::error_code ec, tcp::resolver::results_type const results) -> void
    {
        if (ec)
        {
            fail(cb_, ec, "resolve");
            return;
        }

        // Avoid reallocating the acceptors_ vector when emplacing later
        acceptors_.reserve(results.size());

        for (auto&& result : results)
        {
            auto const endpoint = result.endpoint();
            auto& acceptor = acceptors_.emplace_back(net::make_strand(ioc_));
            acceptor.open(endpoint.protocol(), ec);
            if (ec)
            {
                fail(cb_, ec, "open");
                return;
            }

            acceptor.set_option(net::socket_base::reuse_address(true), ec);
            if (ec)
            {
                fail(cb_, ec, "set_option");
                return;
            }

            acceptor.bind(endpoint, ec);
            if (ec)
            {
                fail(cb_, ec, "bind");
                return;
            }

            acceptor.listen(net::socket_base::max_listen_connections, ec);
            if (ec)
            {
                fail(cb_, ec, "listen");
                return;
            }

            do_accept(acceptor);
        }
    }

    // Start accepting incoming connections
    auto run(std::string_view const host, std::string_view const service) -> void
    {
        resolver_.async_resolve(host, service, tcp::resolver::flags::passive,
            beast::bind_front_handler(&Listener::on_resolve, shared_from_this())
        );
    }

    auto close() -> void
    {
        for (auto& acceptor : acceptors_)
        {
            acceptor.close();
        }
    }

private:
    auto do_accept(tcp::acceptor& acceptor) -> void
    {
        // The new connection gets its own strand
        acceptor.async_accept(
            net::make_strand(ioc_),
            beast::bind_front_handler(&Listener::on_accept, shared_from_this(), std::ref(acceptor))
        );
    }

    auto on_accept(tcp::acceptor& acceptor, beast::error_code ec, tcp::socket socket) -> void
    {
        if (ec)
        {
            fail(cb_, ec, "accept");
            return;
        }

        std::make_shared<Session>(std::move(socket), LuaRef{cb_})->run();
        do_accept(acceptor);
    }
};

luaL_Reg const M[]{
    {"close", [](auto const L) {
         auto& l = *check_udata<std::shared_ptr<Listener>>(L, 1);
         l->close();
         return 0;
     }},
    {}
};
luaL_Reg const MT[]{
    {"__gc", [](auto const L) {
         std::destroy_at(check_udata<std::shared_ptr<Listener>>(L, 1));
         return 0;
     }},
    {}
};

} // namespace

template <>
char const* udata_name<std::shared_ptr<Websocket>> = "websocket";

template <>
char const* udata_name<std::shared_ptr<Listener>> = "listener";

auto start_httpd(lua_State* const L) -> int
{
    auto const host = check_string_view(L, 1);
    auto const service = check_string_view(L, 2);
    lua_settop(L, 3);
    auto cb = LuaRef::create(L);

    auto& httpd = *new_udata<std::shared_ptr<Listener>>(L, 0, [L] {
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, M);
        luaL_setfuncs(L, M, 0);
        lua_setfield(L, -2, "__index");
    });

    std::construct_at(
        &httpd,
        std::make_shared<Listener>(
            App::from_lua(L)->get_executor(),
            std::move(cb)
        )
    );
    httpd->run(host, service);
    return 1;
}
