#include "irc.hpp"

#include "app.hpp"
#include "safecall.hpp"

#include <ircmsg.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <boost/bind.hpp>

#include <charconv> // from_chars
#include <memory>
#include <sstream>
#include <string>
#include <optional>

namespace
{
    /**
     * @brief Push string_view value onto Lua stack
     *
     * @param L Lua
     * @param str string
     * @return char const* string in Lua memory
     */
    auto push_stringview(lua_State *const L, std::string_view const str) -> char const *
    {
        return lua_pushlstring(L, str.data(), str.size());
    }
}

auto pushtags(lua_State *const L, std::vector<irctag> const &tags) -> void
{
    lua_createtable(L, 0, tags.size());
    for (auto &&tag : tags)
    {
        push_stringview(L, tag.key);
        if (tag.hasval())
        {
            push_stringview(L, tag.val);
        }
        else
        {
            lua_pushboolean(L, 1);
        }
        lua_settable(L, -3);
    }
}

namespace
{
    auto pushircmsg(lua_State *const L, ircmsg const &msg) -> void
    {
        lua_createtable(L, msg.args.size(), 3);
        pushtags(L, msg.tags);
        lua_setfield(L, -2, "tags");

        if (msg.hassource())
        {
            push_stringview(L, msg.source);
            lua_setfield(L, -2, "source");
        }

        int code;
        auto res = std::from_chars(msg.command.begin(), msg.command.end(), code);
        if (*res.ptr == '\0')
        {
            lua_pushinteger(L, code);
        }
        else
        {
            push_stringview(L, msg.command);
        }
        lua_setfield(L, -2, "command");

        int argix = 1;
        for (auto arg : msg.args)
        {
            push_stringview(L, arg);
            lua_rawseti(L, -2, argix++);
        }
    }

    class irc_connection
        : public std::enable_shared_from_this<irc_connection>
    {
    protected:
        boost::asio::io_context &io_context;
        boost::asio::streambuf buffer;
        lua_State *L;
        int irc_cb;
        std::optional<int> send_cb;

    public:
        typedef std::shared_ptr<irc_connection> pointer;

        irc_connection(boost::asio::io_context &io_context, lua_State *const L, int const irc_cb)
            : io_context{io_context}, L{L}, irc_cb{irc_cb}
        {
        }

        virtual ~irc_connection()
        {
            luaL_unref(L, LUA_REGISTRYINDEX, irc_cb);
            if (send_cb) {
                luaL_unref(L, LUA_REGISTRYINDEX, *send_cb);
            }
        }

        auto forget_irc_handle() -> void {
            if (send_cb) {
                // Remove send_callback's upvalue pointing to this object
                lua_rawgeti(L, LUA_REGISTRYINDEX, *send_cb);
                lua_pushnil(L);
                lua_setupvalue(L, -2, 1);
                lua_pop(L, 1);
                send_cb = {};
            }
        }

        auto handle_read(const boost::system::error_code &error, size_t bytes_transferred)
        {
            if (!error)
            {
                if (bytes_transferred < 2)
                {
                    buffer.consume(bytes_transferred);
                    start();
                    return;
                }

                auto const p = boost::asio::buffers_begin(buffer.data());
                std::string line_string(p, p + (bytes_transferred - 2));
                buffer.consume(bytes_transferred);

                char *line = line_string.data();
                while (*line == ' ')
                {
                    line++;
                }
                if (*line != '\0')
                {
                    try
                    {
                        auto const msg = parse_irc_message(line); // might throw
                        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                        lua_pushstring(L, "message");
                        pushircmsg(L, msg);
                        safecall(L, "on_irc_line", 2);
                    }
                    catch (irc_parse_error const &e)
                    {
                        std::stringstream msg;
                        msg << "parse_irc_message failed: " << e.code;

                        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                        lua_pushstring(L, "bad message");
                        lua_pushlstring(L, msg.str().data(), msg.str().size());
                        safecall(L, "on_irc_line", 2);
                    }
                }

                start();
            }
            else
            {
                forget_irc_handle();
                lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                lua_pushstring(L, "closed");
                safecall(L, "on_irc_line", 1);
            }
        }

        virtual auto start() -> void = 0;
        virtual auto shutdown() -> void = 0;
        virtual auto write(char const *cmd, size_t n, int ref) -> void = 0;
    };

    class plain_irc_connection final : public irc_connection
    {
    public:

        boost::asio::ip::tcp::socket socket_;
        plain_irc_connection(boost::asio::io_context &io_context, lua_State *const L, int const irc_cb)
            : irc_connection{io_context, L, irc_cb}, socket_{io_context} {}

        static std::shared_ptr<plain_irc_connection> create(boost::asio::io_context &io_context, lua_State *const L, int const irc_cb)
        {
            return std::make_shared<plain_irc_connection>(io_context, L, irc_cb);
        }

        auto start() -> void override
        {
            using namespace std::placeholders;
            boost::asio::async_read_until(socket_, buffer, '\n',
                                          boost::bind(&plain_irc_connection::handle_read, shared_from_this(), boost::asio::placeholders::error, boost::asio::placeholders::bytes_transferred));
        }
        auto shutdown() -> void override
        {
            forget_irc_handle();
            socket_.shutdown(boost::asio::ip::tcp::socket::shutdown_send);
        }
        auto write(char const *const cmd, size_t n, int ref) -> void override
        {
            boost::asio::async_write(socket_, boost::asio::buffer(cmd, n), [L = this->L, ref](auto error, auto amount)
                                     { luaL_unref(L, LUA_REGISTRYINDEX, ref); });
        }

    };

    class tls_irc_connection : public irc_connection
    {
        public:
        boost::asio::ssl::stream<boost::asio::ip::tcp::socket> socket_;


        tls_irc_connection(boost::asio::io_context &io_context, boost::asio::ssl::context &ssl_context, lua_State *const L, int const irc_cb)
            : irc_connection{io_context, L, irc_cb}, socket_{io_context, ssl_context}
        {
        }

        static std::shared_ptr<tls_irc_connection> create(boost::asio::io_context &io_context, boost::asio::ssl::context &ssl_context, lua_State *const L, int const irc_cb)
        {
            return std::make_shared<tls_irc_connection>(io_context, ssl_context, L, irc_cb);
        }

        auto start() -> void override
        {
            boost::asio::async_read_until(socket_, buffer, '\n',
                boost::bind(
                    &plain_irc_connection::handle_read,
                    shared_from_this(),
                    boost::asio::placeholders::error,
                    boost::asio::placeholders::bytes_transferred));
        }
        auto shutdown() -> void override
        {
            forget_irc_handle();
            socket_.shutdown();
        }

        auto write(char const *const cmd, size_t n, int ref) -> void override
        {
            boost::asio::async_write(socket_, boost::asio::buffer(cmd, n), [L = this->L, ref](auto error, auto amount)
                                     { luaL_unref(L, LUA_REGISTRYINDEX, ref); });
        }

    };

    auto on_send_irc(lua_State *L) -> int
    {
        auto const tcp = reinterpret_cast<irc_connection *>(lua_touserdata(L, lua_upvalueindex(1)));

        if (tcp == nullptr)
        {
            luaL_error(L, "send to closed irc");
            return 0;
        }

        size_t n;
        auto const cmd = luaL_optlstring(L, 1, nullptr, &n);
        lua_settop(L, 1);

        if (cmd == nullptr)
        {
            tcp->shutdown();
        }
        else
        {
            auto const ref = luaL_ref(L, LUA_REGISTRYINDEX);
            tcp->write(cmd, n, ref);
        }

        return 0;
    }
}

auto connect_thread(
    boost::asio::io_context & io_context,
    lua_State * const L,
    bool tls,
    std::string host,
    std::string port,
    std::string cert,
    std::string verify,
    int irc_cb
) -> boost::asio::awaitable<void> {
    // store this early - it keeps irc_cb alive even in an error case
    std::shared_ptr<irc_connection> p;

    try {
        auto resolver = boost::asio::ip::tcp::resolver{io_context};
        auto const endpoints = co_await resolver.async_resolve({host, port}, boost::asio::use_awaitable);

        if (not tls)
        {
            auto irc = plain_irc_connection::create(io_context, L, irc_cb);
            p = irc;

            co_await boost::asio::async_connect(irc->socket_, endpoints, boost::asio::use_awaitable);
            p = std::move(irc);
        }
        else
        {
            boost::asio::ssl::context ssl_context{boost::asio::ssl::context::method::tls_client};
            ssl_context.set_default_verify_paths();
            if (not cert.empty())
            {
                ssl_context.use_certificate_file(cert, boost::asio::ssl::context::file_format::pem);
                ssl_context.use_private_key_file(cert, boost::asio::ssl::context::file_format::pem);
            }
            auto irc = tls_irc_connection::create(io_context, ssl_context, L, irc_cb);
            p = irc;

            co_await boost::asio::async_connect(irc->socket_.lowest_layer(), endpoints, boost::asio::use_awaitable);

            irc->socket_.lowest_layer().set_option(boost::asio::ip::tcp::no_delay(true));
            if (not host.empty()) {
                irc->socket_.set_verify_mode(boost::asio::ssl::verify_peer);
                irc->socket_.set_verify_callback(boost::asio::ssl::host_name_verification(host));
            }

            co_await irc->socket_.async_handshake(boost::asio::ssl::stream_base::handshake_type::client, boost::asio::use_awaitable);
        }

        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
        lua_pushstring(L, "connect");    
        lua_pushlightuserdata(L, p.get());
        lua_pushcclosure(L, on_send_irc, 1);
        safecall(L, "successful connect", 2);

        p->start();

    } catch (std::exception &e) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
        lua_pushstring(L, "closed");
        lua_pushstring(L, e.what());
        safecall(L, "plain connect error", 2);
        co_return;
    }
}

auto start_irc(lua_State *const L) -> int
{
    auto const a = App::from_lua(L);

    auto const tls = lua_toboolean(L, 1);
    auto const host = luaL_checkstring(L, 2);
    auto const port = luaL_checkstring(L, 3);
    auto const cert = luaL_optlstring(L, 4, "", nullptr);
    auto const verify = luaL_optlstring(L, 5, host, nullptr);
    luaL_checkany(L, 6); // callback
    lua_settop(L, 6);

    // consume the callback function and name it
    auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);

    boost::asio::co_spawn(
        a->io_context,
        connect_thread(a->io_context, L, tls, host, port, cert, verify, irc_cb),
        boost::asio::detached);
    return 0;
}
