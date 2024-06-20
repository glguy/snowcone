#include "httpd.hpp"
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
#include <boost/config.hpp>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace beast = boost::beast; // from <boost/beast.hpp>
namespace http = beast::http; // from <boost/beast/http.hpp>
namespace net = boost::asio; // from <boost/asio.hpp>
using tcp = boost::asio::ip::tcp; // from <boost/asio/ip/tcp.hpp>
using namespace std::literals::chrono_literals;

// Return a reasonable mime type based on the extension of a file.
auto mime_type(beast::string_view const path) -> beast::string_view
{
    using beast::iequals;
    auto const ext = [&path] {
        auto const pos = path.rfind(".");
        if (pos == beast::string_view::npos)
            return beast::string_view{};
        return path.substr(pos);
    }();
    if (iequals(ext, ".htm"))
        return "text/html";
    if (iequals(ext, ".html"))
        return "text/html";
    if (iequals(ext, ".php"))
        return "text/html";
    if (iequals(ext, ".css"))
        return "text/css";
    if (iequals(ext, ".txt"))
        return "text/plain";
    if (iequals(ext, ".js"))
        return "application/javascript";
    if (iequals(ext, ".json"))
        return "application/json";
    if (iequals(ext, ".xml"))
        return "application/xml";
    if (iequals(ext, ".swf"))
        return "application/x-shockwave-flash";
    if (iequals(ext, ".flv"))
        return "video/x-flv";
    if (iequals(ext, ".png"))
        return "image/png";
    if (iequals(ext, ".jpe"))
        return "image/jpeg";
    if (iequals(ext, ".jpeg"))
        return "image/jpeg";
    if (iequals(ext, ".jpg"))
        return "image/jpeg";
    if (iequals(ext, ".gif"))
        return "image/gif";
    if (iequals(ext, ".bmp"))
        return "image/bmp";
    if (iequals(ext, ".ico"))
        return "image/vnd.microsoft.icon";
    if (iequals(ext, ".tiff"))
        return "image/tiff";
    if (iequals(ext, ".tif"))
        return "image/tiff";
    if (iequals(ext, ".svg"))
        return "image/svg+xml";
    if (iequals(ext, ".svgz"))
        return "image/svg+xml";
    return "application/text";
}

// Return a response for the given request.
//
// The concrete type of the response message (which depends on the
// request), is type-erased in message_generator.
template <class Body, class Allocator>
auto handle_request(
    lua_State* const L,
    int const cb,
    http::request<Body, http::basic_fields<Allocator>>&& req
) -> http::message_generator
{
    // Returns a server error response
    auto const server_error =
        [&req](beast::string_view what) {
            http::response<http::string_body> res{http::status::internal_server_error, req.version()};
            res.set(http::field::server, BOOST_BEAST_VERSION_STRING);
            res.set(http::field::content_type, "text/html");
            res.keep_alive(req.keep_alive());
            res.body() = "An error occurred: '" + std::string(what) + "'";
            res.prepare_payload();
            return res;
        };

    // Build the path to the requested file
    std::string path = req.target();
    if (req.target().back() == '/')
    {
        path.append("index.html");
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX, cb);
    push_string(L, req.method_string());
    push_string(L, path);
    if (LUA_OK != lua_pcall(L, 2, 1, 0))
    {
        std::string const err = lua_tostring(L, -1);
        lua_pop(L, 1);
        return server_error(err);
    }

    // Attempt to open the file
    std::size_t len;
    auto const body_ptr = lua_tolstring(L, -1, &len);
    std::string body{body_ptr, len};
    lua_pop(L, 1);

    if (req.method() == http::verb::head)
    {
        http::response<http::empty_body> res{http::status::ok, req.version()};
        res.set(http::field::server, BOOST_BEAST_VERSION_STRING);
        res.set(http::field::content_type, mime_type(path));
        res.content_length(body.size());
        res.keep_alive(req.keep_alive());
        return res;
    }

    http::response<http::string_body> res{http::status::ok, req.version()};
    res.set(http::field::server, BOOST_BEAST_VERSION_STRING);
    res.set(http::field::content_type, mime_type(path));
    res.content_length(body.size());
    res.body() = std::move(body);
    res.keep_alive(req.keep_alive());
    return res;
}

//------------------------------------------------------------------------------

// Report a failure
void fail(lua_State * const L, int const cb, beast::error_code ec, char const* what)
{
    lua_rawgeti(L, LUA_REGISTRYINDEX, cb);
    luaL_pushfail(L);
    lua_pushstring(L, what);
    push_string(L, ec.message());
    safecall(L, "httpd error", 3);
}

// Handles an HTTP server connection
class session : public std::enable_shared_from_this<session>
{
    beast::tcp_stream stream_;
    beast::flat_buffer buffer_;
    lua_State* L_;
    int cb_;
    http::request<http::string_body> req_;

public:
    // Take ownership of the stream
    session(
        tcp::socket&& socket,
        lua_State* const L,
        int const cb
    )
        : stream_(std::move(socket))
        , L_{L}
    {
        lua_geti(L, LUA_REGISTRYINDEX, cb);
        cb_ = luaL_ref(L, LUA_REGISTRYINDEX);
    }

    ~session()
    {
        luaL_unref(L_, LUA_REGISTRYINDEX, cb_);
    }

    auto run() -> void
    {
        // We need to be executing within a strand to perform async operations
        // on the I/O objects in this session. Although not strictly necessary
        // for single-threaded contexts, this example code is written to be
        // thread-safe by default.
        net::dispatch(stream_.get_executor(), beast::bind_front_handler(&session::do_read, shared_from_this()));
    }

    auto do_read() -> void
    {
        // Make the request empty before reading,
        // otherwise the operation behavior is undefined.
        req_ = {};

        // Set the timeout.
        stream_.expires_after(30s);

        // Read a request
        http::async_read(stream_, buffer_, req_, beast::bind_front_handler(&session::on_read, shared_from_this()));
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
            return fail(L_, cb_, ec, "read");
        }

        send_response(handle_request(L_, cb_, std::move(req_)));
    }

    auto send_response(http::message_generator&& msg) -> void
    {
        bool keep_alive = msg.keep_alive();

        // Write the response
        beast::async_write(
            stream_,
            std::move(msg),
            beast::bind_front_handler(
                &session::on_write, shared_from_this(), keep_alive
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
            return fail(L_, cb_, ec, "write");
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
class listener : public std::enable_shared_from_this<listener>
{
    net::io_context& ioc_;
    tcp::acceptor acceptor_;
    lua_State* L_;
    int cb_;

public:
    listener(
        net::io_context& ioc,
        tcp::endpoint endpoint,
        lua_State* const L,
        int const cb
    )
        : ioc_{ioc}
        , acceptor_{net::make_strand(ioc)}
        , L_{L}
        , cb_{cb}
    {
        beast::error_code ec;

        acceptor_.open(endpoint.protocol(), ec);
        if (ec)
        {
            fail(L, cb, ec, "open");
            return;
        }

        acceptor_.set_option(net::socket_base::reuse_address(true), ec);
        if (ec)
        {
            fail(L, cb, ec, "set_option");
            return;
        }

        acceptor_.bind(endpoint, ec);
        if (ec)
        {
            fail(L, cb, ec, "bind");
            return;
        }

        acceptor_.listen(net::socket_base::max_listen_connections, ec);
        if (ec)
        {
            fail(L, cb, ec, "listen");
            return;
        }
    }

    ~listener()
    {
        luaL_unref(L_, LUA_REGISTRYINDEX, cb_);
    }

    // Start accepting incoming connections
    auto run() -> void
    {
        do_accept();
    }

    auto close() -> void
    {
        acceptor_.close();
    }

private:
    auto do_accept() -> void
    {
        // The new connection gets its own strand
        acceptor_.async_accept(
            net::make_strand(ioc_),
            beast::bind_front_handler(
                &listener::on_accept,
                shared_from_this()
            )
        );
    }

    auto on_accept(beast::error_code ec, tcp::socket socket) -> void
    {
        if (ec)
        {
            fail(L_, cb_, ec, "accept");
            return;
        }

        std::make_shared<session>(std::move(socket), L_, cb_)->run();
        do_accept();
    }
};

template <>
char const* udata_name<std::shared_ptr<listener>> = "listener";

auto start_httpd(lua_State* const L) -> int
{
    boost::asio::ip::port_type const port = lua_tointeger(L, 1);
    lua_settop(L, 2);
    auto const cb = luaL_ref(L, LUA_REGISTRYINDEX);

    auto const httpd = new_udata<std::shared_ptr<listener>>(L, 0, [L] {
        luaL_Reg const M[]{
            {"close", [](auto const L) {
                 auto const httpd = check_udata<std::shared_ptr<listener>>(L, 1);
                 (*httpd)->close();
                 return 0;
             }},
            {}
        };
        luaL_Reg const MT[]{
            {"__gc", [](auto const L) {
                 auto const httpd = check_udata<std::shared_ptr<listener>>(L, 1);
                 (*httpd)->close();
                 std::destroy_at(httpd);
                 return 0;
             }},
            {}
        };
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, M);
        luaL_setfuncs(L, M, 0);
        lua_setfield(L, -2, "__index");
    });

    auto const app = App::from_lua(L);
    std::construct_at(httpd);
    *httpd = std::make_shared<listener>(app->get_executor(), tcp::endpoint{{}, port}, L, cb);
    (*httpd)->run();
    return 1;
}
