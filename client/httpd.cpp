#include "httpd.hpp"
#include "LuaRef.hpp"
#include "app.hpp"
#include "boundary.hpp"
#include "safecall.hpp"
#include "strings.hpp"
#include "userdata.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <boost/asio/dispatch.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/strand.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>
#include <boost/config.hpp>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>


namespace beast = boost::beast; // from <boost/beast.hpp>
namespace http = beast::http; // from <boost/beast/http.hpp>
namespace net = boost::asio; // from <boost/asio.hpp>
using tcp = net::ip::tcp; // from <boost/asio/ip/tcp.hpp>
using namespace std::literals;

namespace {

// Report an error to the Lua callback as: cb(nil, what, message)
auto report(LuaRef const& cb, char const* const what, std::string_view const message) -> void
{
    auto const L = cb.get_lua();
    cb.push();
    luaL_pushfail(L);
    lua_pushstring(L, what);
    push_string(L, message);
    safecall(L, "httpd error", 3);
}

// Message handler for the request handler's pcall: the error as text, with a
// traceback. luaL_tolstring makes any error object safe to report.
auto traceback(lua_State* const L) -> int
{
    auto const msg = luaL_tolstring(L, 1, nullptr);
    luaL_traceback(L, L, msg, 1);
    return 1;
}

// Header text from Lua can't contain characters that would split the response
auto valid_header_text(std::string_view const text) -> bool
{
    return text.find_first_of("\r\n\0"sv) == std::string_view::npos;
}

// Returns a server error response
template <class Body, class Allocator>
auto server_error(
    http::request<Body, http::basic_fields<Allocator>> const& req,
    std::string_view const what
) -> http::response<http::string_body>
{
    http::response<http::string_body> res{http::status::internal_server_error, req.version()};
    res.set(http::field::server, BOOST_BEAST_VERSION_STRING);
    res.set(http::field::content_type, "text/plain");
    res.keep_alive(req.keep_alive());
    res.body() = what;
    res.prepare_payload();
    return res;
}

// Call the Lua handler and build a response from its results. This can throw
// while building the response, leaving values on the Lua stack. An error or
// an invalid result is reported locally; the client only sees a generic 500.
template <class Body, class Allocator>
auto build_response(
    LuaRef const& cb,
    http::request<Body, http::basic_fields<Allocator>> const& req
) -> http::message_generator
{
    auto const L = cb.get_lua();
    auto const base = lua_gettop(L);
    lua_pushcfunction(L, traceback);
    cb.push();
    push_string(L, req.method_string());
    push_string(L, req.target());
    push_string(L, req.body());

    // Header names are case-insensitive, so handlers get them in lower case
    lua_newtable(L);
    for (auto&& field : req) {
        std::string name{field.name_string()};
        for (auto& c : name) {
            if ('A' <= c && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        }
        push_string(L, name);
        push_string(L, field.value());
        lua_settable(L, -3);
    }

    if (LUA_OK != lua_pcall(L, 4, 3, base + 1))
    {
        // Report the error locally; don't send internals to the client.
        // The message handler made it a string, unless it failed itself.
        auto const err = lua_tostring(L, -1);
        std::string const message = err ? err : "error object is not a string";
        lua_settop(L, base);
        report(cb, "handler", message);
        return server_error(req, "internal server error"sv);
    }

    // No status at all is the handler's way to give a 500
    if (lua_isnil(L, -3))
    {
        lua_settop(L, base);
        return server_error(req, "internal server error"sv);
    }

    int is_integer;
    auto const code = lua_tointegerx(L, -3, &is_integer);
    if (not is_integer || code < 100 || code > 999)
    {
        lua_settop(L, base);
        report(cb, "handler", "status must be an integer from 100 to 999");
        return server_error(req, "internal server error"sv);
    }

    http::response<http::string_body> res;
    res.version(req.version());
    res.result(static_cast<unsigned>(code));
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
            // Only a string key: converting a number key in place would break lua_next
            auto const key = to_string_view(L, -2);
            // A number value is converted in place, which is harmless for a value
            std::size_t val_len;
            auto const val = lua_isstring(L, -1) ? lua_tolstring(L, -1, &val_len) : nullptr;
            if (not key || val == nullptr
                || not valid_header_text(*key)
                || not valid_header_text({val, val_len}))
            {
                lua_settop(L, base);
                report(cb, "handler", "header names and values must be strings without CR, LF or NUL");
                return server_error(req, "internal server error"sv);
            }
            res.set(*key, std::string_view{val, val_len});
            lua_pop(L, 1); // remove value
        }
    }

    lua_settop(L, base);

    return res;
}

// Return a response for the given request.
//
// The concrete type of the response message (which depends on the
// request), is type-erased in message_generator.
template <class Body, class Allocator>
auto handle_request(
    LuaRef const& cb,
    http::request<Body, http::basic_fields<Allocator>> const& req
) -> http::message_generator
{
    auto const L = cb.get_lua();
    auto const top = lua_gettop(L);
    try
    {
        return build_response(cb, req);
    }
    catch (std::exception const& e)
    {
        lua_settop(L, top);
        report(cb, "response", e.what());
        return server_error(req, "internal server error"sv);
    }
}

//------------------------------------------------------------------------------

void fail(LuaRef const& cb, beast::error_code const ec, char const* const what)
{
    report(cb, what, ec.message());
}

/// GitHub caps webhook payloads at 25 MB; Beast's default limit is 1 MiB.
constexpr std::uint64_t max_body_size = 25 * 1024 * 1024;

class Session : public std::enable_shared_from_this<Session>
{
    beast::tcp_stream stream_;
    beast::flat_buffer buffer_;
    LuaRef cb_;
    std::optional<http::request_parser<http::string_body>> parser_;
    bool closed_ = false; // set by close(); later completions return quietly

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

    /// Abandon the connection, including any request or response in flight.
    /// This never calls into Lua.
    auto close() -> void
    {
        if (not closed_)
        {
            closed_ = true;
            stream_.close();
        }
    }

    auto do_read() -> void
    {
        if (closed_)
        {
            return;
        }

        // A fresh parser for each request; limits are per parser
        parser_.emplace();
        parser_->body_limit(max_body_size);
        stream_.expires_after(30s);
        http::async_read(stream_, buffer_, *parser_, beast::bind_front_handler(&Session::on_read, shared_from_this()));
    }

    auto on_read(
        beast::error_code const ec,
        std::size_t
    ) -> void
    {
        if (closed_)
        {
            return;
        }

        // This means they closed the connection
        if (ec == http::error::end_of_stream)
        {
            return do_close();
        }

        // An idle keep-alive connection timing out between requests is normal
        // (proxies hold upstream connections open longer than 30 s)
        if (ec == beast::error::timeout and not parser_->got_some() and buffer_.size() == 0)
        {
            return;
        }

        if (ec)
        {
            fail(cb_, ec, "read");

            // Tell the client why. The rest of the request is unread, so the
            // connection can't be reused.
            if (ec == http::error::body_limit)
            {
                send_response(limit_response(http::status::payload_too_large));
            }
            else if (ec == http::error::header_limit)
            {
                send_response(limit_response(http::status::request_header_fields_too_large));
            }
            return;
        }

        auto msg = handle_request(cb_, parser_->get());

        // The handler may have closed the listener, and with it this session
        if (not closed_)
        {
            send_response(std::move(msg));
        }
    }

    auto limit_response(http::status const status) const -> http::response<http::string_body>
    {
        http::response<http::string_body> res{status, parser_->get().version()};
        res.set(http::field::server, BOOST_BEAST_VERSION_STRING);
        res.set(http::field::content_type, "text/plain");
        res.keep_alive(false);
        res.body() = http::obsolete_reason(status);
        res.prepare_payload();
        return res;
    }

    auto send_response(http::message_generator&& msg) -> void
    {
        auto const keep_alive = msg.keep_alive();

        // Write the response; a slow upload doesn't eat into the write's time
        stream_.expires_after(30s);
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
        if (closed_)
        {
            return;
        }

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

/// How long to wait before accepting again after an accept error
constexpr auto accept_retry_delay = 1s;

// Accepts incoming connections and launches the sessions
class Listener : public std::enable_shared_from_this<Listener>
{
    struct Acceptor
    {
        tcp::acceptor acceptor;
        net::steady_timer retry; // backoff after an accept error

        explicit Acceptor(net::strand<net::io_context::executor_type> const& executor)
            : acceptor{executor}
            , retry{executor}
        {
        }
    };

    net::io_context& ioc_;
    std::vector<Acceptor> acceptors_;
    std::vector<std::weak_ptr<Session>> sessions_; // closed along with the listener
    tcp::resolver resolver_;
    LuaRef const cb_;
    bool closed_ = false; // set by close(); later completions return quietly

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
        // A close() during the resolve must not bind
        if (closed_)
        {
            return;
        }

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
            auto& entry = acceptors_.emplace_back(net::make_strand(ioc_));
            auto& acceptor = entry.acceptor;
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

            do_accept(entry);
        }
    }

    // Start accepting incoming connections
    auto run(std::string_view const host, std::string_view const service) -> void
    {
        resolver_.async_resolve(host, service, tcp::resolver::flags::passive,
            beast::bind_front_handler(&Listener::on_resolve, shared_from_this())
        );
    }

    /// Stop listening and drop every open connection. Idempotent, and never
    /// calls into Lua, so it is safe from a handler and from __gc.
    auto close() -> void
    {
        if (closed_)
        {
            return;
        }
        closed_ = true;

        resolver_.cancel();

        for (auto& entry : acceptors_)
        {
            beast::error_code ec;
            entry.acceptor.close(ec);
            entry.retry.cancel();
        }

        for (auto const& weak : sessions_)
        {
            if (auto const session = weak.lock())
            {
                session->close();
            }
        }
        sessions_.clear();
    }

private:
    auto do_accept(Acceptor& entry) -> void
    {
        // The new connection gets its own strand
        entry.acceptor.async_accept(
            net::make_strand(ioc_),
            beast::bind_front_handler(&Listener::on_accept, shared_from_this(), std::ref(entry))
        );
    }

    auto on_accept(Acceptor& entry, beast::error_code const ec, tcp::socket socket) -> void
    {
        if (closed_)
        {
            return;
        }

        if (ec)
        {
            fail(cb_, ec, "accept");

            // The peer gave up before the accept finished: nothing is wrong here
            if (ec == net::error::connection_aborted)
            {
                return do_accept(entry);
            }

            // Anything else (typically running out of descriptors) is retried
            // after a pause so a persistent error can't spin
            entry.retry.expires_after(accept_retry_delay);
            entry.retry.async_wait(
                beast::bind_front_handler(&Listener::on_retry, shared_from_this(), std::ref(entry))
            );
            return;
        }

        std::erase_if(sessions_, [](auto const& weak) { return weak.expired(); });
        auto const session = std::make_shared<Session>(std::move(socket), LuaRef{cb_});
        sessions_.push_back(session);
        session->run();
        do_accept(entry);
    }

    auto on_retry(Acceptor& entry, beast::error_code const ec) -> void
    {
        if (not closed_ and not ec)
        {
            do_accept(entry);
        }
    }
};

auto l_listener_close(lua_State* const L) -> int
{
    auto& l = *check_udata<std::shared_ptr<Listener>>(L, 1);
    l->close();
    return 0;
}

auto l_listener_gc(lua_State* const L) -> int
{
    // Unreachable from Lua means nothing could close it later
    auto const l = check_udata<std::shared_ptr<Listener>>(L, 1);
    (*l)->close();
    std::destroy_at(l);
    return 0;
}

luaL_Reg const M[]{
    {"close", boundary<l_listener_close>},
    {}
};
luaL_Reg const MT[]{
    {"__gc", boundary<l_listener_gc>},
    {}
};

} // namespace

template <>
char const* udata_name<std::shared_ptr<Listener>> = "listener";

auto start_httpd(lua_State* const L) -> int
{
    auto const host = check_c_string(L, 1);
    auto const service = check_c_string(L, 2);
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
            App::from_lua(L)->get_context(),
            std::move(cb)
        )
    );
    httpd->run(host, service);
    return 1;
}
