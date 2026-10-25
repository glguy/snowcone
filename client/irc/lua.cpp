#include "lua.hpp"
#include "../app.hpp"
#include "../boundary.hpp"
#include "../net/connection.hpp"
#include "../net/linebuffer.hpp"
#include "../safecall.hpp"
#include "../strings.hpp"
#include "../userdata.hpp"

#include <pkey.hpp>
#include <x509.hpp>

#include <openssl/err.h>

#include <ircmsg.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <charconv> // from_chars
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <variant>

namespace {

using namespace std::literals::string_view_literals;

auto l_close_irc(lua_State* const L) -> int
{
    auto const w = check_udata<std::weak_ptr<connection>>(L, 1);

    if (auto const irc = w->lock())
    {
        irc->close();
        w->reset();
        lua_pushboolean(L, 1);
        return 1;
    }
    else
    {
        luaL_pushfail(L);
        push_string(L, "irc handle destructed"sv);
        return 2;
    }
}

auto l_send_irc(lua_State* const L) -> int
{
    auto const w = check_udata<std::weak_ptr<connection>>(L, 1);
    auto const cmd = check_string_view(L, 2);

    if (auto const irc = w->lock())
    {
        irc->write(cmd);
        lua_pushboolean(L, 1);
        return 1;
    }
    else
    {
        luaL_pushfail(L);
        push_string(L, "irc handle destructed"sv);
        return 2;
    }
}

auto pushirc(lua_State* const L, std::weak_ptr<connection> const irc) -> void
{
    auto const w = new_udata<std::weak_ptr<connection>>(L, 1, [L] {
        auto constexpr l_gc = [](lua_State* const L) -> int {
            auto const w = check_udata<std::weak_ptr<connection>>(L, 1);
            std::destroy_at(w);
            return 0;
        };

        luaL_Reg const MT[]{
            {"__gc", boundary<l_gc>},
            {},
        };
        luaL_setfuncs(L, MT, 0);

        // Setup class methods for IRC objects
        luaL_Reg const Methods[]{
            {"send", boundary<l_send_irc>},
            {"close", boundary<l_close_irc>},
            {}
        };
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    });
    std::construct_at(w, irc);
}

/// Retrieve the next non-empty line from the buffer.
///
/// Leading spaces are trimmed from each line before checking for emptiness.
/// The function returns a pointer to the first non-empty line found, or
/// `nullptr` if no such line is available.
///
/// @param buff Reference to a LineBuffer to read lines from.
/// @return Pointer to the next non-empty line, or nullptr if none remain.
auto get_nonempty_line(LineBuffer& buff) -> char*
{
    while (auto line = buff.next_line())
    {
        while (' ' == *line)
        {
            line++;
        }
        if ('\0' != *line)
        {
            return line;
        }
    }
    return nullptr;
}

/// Connect, then read messages from the stream and invoke the Lua callback.
///
/// A callback may close the connection. That is checked after every callback
/// so no further events are delivered and the closed stream is never read.
/// In that case the coroutine simply returns.
///
/// @param L The main Lua state (callbacks never run on a coroutine's state).
/// @param irc_cb The Lua callback function reference.
/// @param irc The shared pointer to the IRC connection.
/// @param settings The settings for the IRC connection.
/// @throws std::runtime_error if the line buffer is full.
auto run_session(
    lua_State* const L,
    int const irc_cb,
    std::shared_ptr<connection> const irc,
    Settings settings
) -> boost::asio::awaitable<void>
{
    // Connect and invoke the callback function:
    // cb("CON", fingerprint)
    {
        auto const fingerprint = co_await irc->connect(std::move(settings));

        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
        push_string(L, "CON"sv);
        push_string(L, fingerprint);
        safecall(L, "successful connect"sv, 2);

        if (irc->closed())
        {
            co_return;
        }
    }

    // Continuously process lines from the stream and invoke the callback
    // cb("MSG", ircmsg, redraw)
    for (LineBuffer buff{connection::irc_buffer_size};;)
    {
        auto const target = buff.prepare();
        if (target.size() == 0)
        {
            throw std::runtime_error{"line buffer full"};
        }

        buff.commit(co_await irc->get_stream().async_read_some(target, boost::asio::use_awaitable));
        for (auto line = get_nonempty_line(buff); nullptr != line; /* empty */)
        {
            auto const msg = parse_irc_message(line); // might throw
            line = get_nonempty_line(buff); // pre-load next line

            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            push_string(L, "MSG"sv);
            pushircmsg(L, msg);
            lua_pushboolean(L, nullptr == line); // draw on last line
            safecall(L, "irc message"sv, 3);

            if (irc->closed())
            {
                co_return;
            }
        }
        buff.shift();
    }
}

/// Coroutine that handles the IRC session.
///
/// Runs the session and then always closes the connection, whichever way the
/// session ended. Otherwise a write still in flight would keep the socket
/// open (and Lua able to send on it) until that write completed.
///
/// A failure that follows a local close() (the read on the closed stream, a
/// cancelled connect) is just the consequence of that close, so it ends the
/// session normally instead of being reported as an error.
///
/// @param L The main Lua state.
/// @param irc_cb The Lua callback function reference.
/// @param irc The shared pointer to the IRC connection.
/// @param settings The settings for the IRC connection.
auto session_thread(
    lua_State* const L,
    int const irc_cb,
    std::shared_ptr<connection> const irc,
    Settings settings
) -> boost::asio::awaitable<void>
{
    std::exception_ptr failure;
    try
    {
        co_await run_session(L, irc_cb, irc, std::move(settings));
    }
    catch (...)
    {
        failure = std::current_exception();
    }

    auto const closed_locally = irc->closed();
    irc->close();

    if (failure && not closed_locally)
    {
        std::rethrow_exception(failure);
    }
}

/// Push t[k] without invoking metamethods (no Lua code can run, so nothing
/// can raise or change the table between validation and use). `t` must be an
/// absolute stack index.
auto raw_field(lua_State* const L, int const t, char const* const k) -> int
{
    lua_pushstring(L, k);
    return lua_rawget(L, t);
}

/// Whether a layer string may hold any bytes, or is handed to a C API
/// (resolver, OpenSSL) that would stop at a NUL
enum class Bytes { Any, CString };

/// Raise a Lua error unless the value at the top of the stack is a string
/// (or nil/absent when `required` is false), without NUL bytes for
/// Bytes::CString. Pops the value. Returns whether a string was given.
auto check_layer_string(lua_State* const L, lua_Integer const n, char const* const field, bool const required, Bytes const bytes) -> bool
{
    auto const absent = lua_type(L, -1) <= LUA_TNIL;
    auto const str = to_string_view(L, -1);
    lua_pop(L, 1);
    if (not required && absent)
    {
        return false;
    }
    if (bytes == Bytes::CString && not (str && not has_nul(*str)))
    {
        luaL_error(L, "layer %d: '%s' must be a string without NUL bytes", static_cast<int>(n), field);
    }
    if (not str)
    {
        luaL_error(L, "layer %d: '%s' must be a string", static_cast<int>(n), field);
    }
    return true;
}

/// Raise a Lua error unless the value at the top of the stack is an integer
/// in [1, 65535]. Pops the value.
auto check_layer_port(lua_State* const L, lua_Integer const n) -> void
{
    int isinteger;
    auto const port = lua_tointegerx(L, -1, &isinteger);
    lua_pop(L, 1);
    if (isinteger && port >= 1 && port <= 65535)
    {
        return;
    }
    luaL_error(L, "layer %d: 'port' must be an integer from 1 to 65535", static_cast<int>(n));
}

/// Validate the layers table at stack index `layers` before any C++ objects
/// are built from it. Raising a Lua error longjmps past C++ destructors, so
/// every check that can fail happens here, while only integers are live.
/// Unknown or missing layer types are errors rather than being skipped, since
/// skipping a layer (for example a misspelled "tls") would quietly give a
/// connection without the protection the configuration asked for.
///
/// A TLS layer verifies against the host it runs over unless told otherwise.
/// Over a local socket, with no proxy in between, there is no such host, so
/// `verify` must be given: a hostname, or "" to disable verification.
auto validate_layers(lua_State* const L, int const layers, lua_Integer const layers_n, bool const local_base) -> void
{
    luaL_checktype(L, layers, LUA_TTABLE);

    bool have_host = not local_base;

    for (lua_Integer i = 1; i <= layers_n; ++i)
    {
        auto const n = static_cast<int>(i);

        if (lua_rawgeti(L, layers, i) != LUA_TTABLE)
        {
            luaL_error(L, "layer %d: must be a table", n);
        }
        auto const layer = lua_gettop(L);

        // The type string stays on the stack so the view into it stays valid
        raw_field(L, layer, "type");
        auto const type = to_string_view(L, -1).value_or(""sv);
        if (type.empty() || has_nul(type))
        {
            luaL_error(L, "layer %d: missing or non-string 'type'", n);
        }

        if (type == "tls"sv)
        {
            raw_field(L, layer, "client_cert");
            auto const cert = myopenssl::test_x509(L, -1);
            if (not cert && not lua_isnil(L, -1))
            {
                luaL_error(L, "layer %d: 'client_cert' must be an open x509", n);
            }
            lua_pop(L, 1);

            raw_field(L, layer, "client_key");
            auto const key = myopenssl::test_pkey(L, -1);
            if (not key && not lua_isnil(L, -1))
            {
                luaL_error(L, "layer %d: 'client_key' must be an open pkey", n);
            }
            lua_pop(L, 1);

            if ((cert == nullptr) != (key == nullptr))
            {
                luaL_error(L, "layer %d: 'client_cert' and 'client_key' must be given together", n);
            }
            if (cert && key && 1 != X509_check_private_key(cert, key))
            {
                ERR_clear_error();
                luaL_error(L, "layer %d: 'client_key' does not match 'client_cert'", n);
            }

            raw_field(L, layer, "verify");
            auto const verify_given = check_layer_string(L, i, "verify", false, Bytes::CString);

            raw_field(L, layer, "sni");
            check_layer_string(L, i, "sni", false, Bytes::CString);

            if (not have_host && not verify_given)
            {
                luaL_error(L, "layer %d: tls over a local socket requires 'verify' "
                              "(a hostname, or \"\" to disable verification)", n);
            }
        }
        else if (type == "socks"sv || type == "http"sv)
        {
            raw_field(L, layer, "host");
            check_layer_string(L, i, "host", true, Bytes::CString);

            raw_field(L, layer, "port");
            check_layer_port(L, i);

            raw_field(L, layer, "username");
            // Credentials are sent with their lengths, so any bytes are fine
            auto const username_given = check_layer_string(L, i, "username", false, Bytes::Any);

            raw_field(L, layer, "password");
            auto const password_given = check_layer_string(L, i, "password", false, Bytes::Any);

            // Either one alone would quietly connect without authenticating
            if (username_given != password_given)
            {
                luaL_error(L, "layer %d: 'username' and 'password' must be given together", n);
            }

            have_host = true;
        }
        else
        {
            luaL_error(L, "layer %d: unknown type '%s'", n, lua_tostring(L, layer + 1));
        }

        lua_pop(L, 2); // layer type, layer table
    }
}

} // namespace

/**
 * @brief Start a new IRC session
 *
 * param:       string      IRC server hostname (socket path when port is 0)
 * param:       integer     IRC server port number, 0..65535; 0 means a local socket
 * param:       table       Array of layers; each has a `type` of "tls", "socks" or "http"
 * param:       function    Callback function for events on IRC session
 *
 * Layers are applied in order on top of the base connection:
 * - { type = "tls", client_cert = X509?, client_key = PKey?,
 *     verify = string?, sni = string? }
 * - { type = "socks", host = string, port = integer, username = string?,
 *     password = string? }
 * - { type = "http", host = string, port = integer, username = string?,
 *     password = string? }
 * A tls layer's `verify` is the name the certificate must match ("" disables
 * verification) and `sni` the server name sent. Either one, when given and
 * non-empty, is the default for the other; otherwise both default to the
 * host the layer runs over (the base host, or the host of the nearest socks
 * or http layer before it). Over a local socket with no proxy in between,
 * `verify` is required.
 *
 * A missing or unknown `type`, or a bad field, raises a Lua error before any
 * connection is started.
 *
 * Callback events:
 * - cb("CON", fingerprint)
 * - cb("MSG", ircmsg, redraw)
 * - cb("END", error_message)
 *
 * error_message is nil when the session ended because the connection was
 * closed locally.
 *
 * Callback sequence: (CON MSG*)? END. No CON or MSG is delivered after the
 * callback that closed the connection returns.
 *
 * @param L Lua state
 * @return int 1
 */
auto l_start_irc(lua_State* const L) -> int
{
    auto const host = check_c_string(L, 1);
    auto const port = luaL_checkinteger(L, 2);
    luaL_argcheck(L, 0 <= port && port <= 65535, 2, "port out of range");
    luaL_checktype(L, 3, LUA_TTABLE); // layers
    luaL_checkany(L, 4); // callback
    lua_settop(L, 4);

    // Raw length: a __len metamethod could change its answer between passes
    auto const layers_n = static_cast<lua_Integer>(lua_rawlen(L, 3));
    validate_layers(L, 3, layers_n, port == 0);

    std::variant<IpLayer, LocalLayer> base;

    if (port == 0)
    {
        base = LocalLayer{
            .path = std::string{host}
        };
    }
    else
    {
        base = IpLayer{
            .host = std::string{host},
            .port = static_cast<std::uint16_t>(port)
        };
    }

    std::vector<AnyLayer> layers;
    layers.reserve(layers_n);

    // The host the next layer runs over; empty over a local socket
    std::string hop_host = port == 0 ? "" : std::string{host};

    for (lua_Integer i{0}; i < layers_n; ++i)
    {
        lua_rawgeti(L, 3, i + 1); // 5 - layer table
        raw_field(L, 5, "type"); // 6 - layer type
        // Validated above, so these reads can't fail
        auto const layer_type = *to_string_view(L, 6);
        if (layer_type == "tls"sv)
        {

            TlsLayer layer;

            raw_field(L, 5, "client_cert"); // 7
            layer.client_cert = luaL_opt(L, myopenssl::check_x509, 7, nullptr);
            lua_pop(L, 1);

            raw_field(L, 5, "client_key"); // 7
            layer.client_key = luaL_opt(L, myopenssl::check_pkey, 7, nullptr);
            lua_pop(L, 1);

            raw_field(L, 5, "verify"); // 7
            raw_field(L, 5, "sni"); // 8
            auto names = tls_names::resolve(to_string_view(L, 7), to_string_view(L, 8), hop_host);
            layer.verify = std::move(names.verify);
            layer.sni = std::move(names.sni);
            lua_pop(L, 2);

            layers.emplace_back(std::move(layer));
        }
        else if (layer_type == "socks"sv)
        {
            SocksLayer layer;

            raw_field(L, 5, "host"); // 7
            layer.host = *to_string_view(L, 7);
            hop_host = layer.host;
            lua_pop(L, 1);

            raw_field(L, 5, "port"); // 7
            layer.port = lua_tointeger(L, 7);
            lua_pop(L, 1);

            raw_field(L, 5, "username"); // 7
            raw_field(L, 5, "password"); // 8
            auto const username = to_string_view(L, 7);
            auto const password = to_string_view(L, 8);

            if (username && password)
            {
                layer.auth = socks5::UsernamePasswordCredential{
                    .username = std::string{*username},
                    .password = std::string{*password},
                };
            }
            else
            {
                layer.auth = socks5::NoCredential{};
            }

            lua_pop(L, 2);

            layers.emplace_back(std::move(layer));
        }
        else if (layer_type == "http"sv)
        {
            HttpLayer layer;

            raw_field(L, 5, "host"); // 7
            layer.host = *to_string_view(L, 7);
            hop_host = layer.host;
            lua_pop(L, 1);

            raw_field(L, 5, "port"); // 7
            layer.port = lua_tointeger(L, 7);
            lua_pop(L, 1);

            raw_field(L, 5, "username"); // 7
            raw_field(L, 5, "password"); // 8
            auto const username = to_string_view(L, 7);
            auto const password = to_string_view(L, 8);

            if (username && password)
            {
                layer.auth = socks5::UsernamePasswordCredential{
                    .username = std::string{*username},
                    .password = std::string{*password},
                };
            }
            else
            {
                layer.auth = socks5::NoCredential{};
            }

            lua_pop(L, 2);

            layers.emplace_back(std::move(layer));
        }
        else
        {
            luaL_error(L, "unknown layer type"); // unreachable: validated above
        }

        lua_pop(L, 2); // layer table, layer type
    }

    Settings settings{
        .base = base,
        .layers = std::move(layers),
    };

    auto const app = App::from_lua(L);
    auto& io_context = app->get_context();
    auto const LMain = app->get_lua();

    auto const irc = connection::create(io_context);
    auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);
    boost::asio::co_spawn(
        io_context, session_thread(LMain, irc_cb, irc, std::move(settings)),
        [L = LMain, irc_cb](std::exception_ptr const e) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            luaL_unref(L, LUA_REGISTRYINDEX, irc_cb);
            push_string(L, "END"sv);

            try
            {
                if (e)
                {
                    std::rethrow_exception(e);
                }
                lua_pushnil(L); // ended without error (closed locally)
            }
            catch (std::exception const& ex)
            {
                push_string(L, ex.what());
            }
            catch (...)
            {
                lua_pushnil(L);
            }

            safecall(L, "end of connection", 2);
        }
    );

    pushirc(L, irc);
    return 1;
}

auto pushircmsg(lua_State* const L, ircmsg const& msg) -> void
{
    lua_createtable(L, msg.args.size(), 3);
    pushtags(L, msg.tags);
    lua_setfield(L, -2, "tags");

    if (not msg.source.empty())
    {
        push_string(L, msg.source);
        lua_setfield(L, -2, "source");
    }

    lua_Integer code;
    auto const [last, ec] = std::from_chars(msg.command.begin(), msg.command.end(), code);
    if (ec == std::errc{} && last == msg.command.end())
    {
        lua_pushinteger(L, code);
    }
    else
    {
        push_string(L, msg.command);
    }
    lua_setfield(L, -2, "command");

    int argix = 1;
    for (auto const arg : msg.args)
    {
        push_string(L, arg);
        lua_rawseti(L, -2, argix++);
    }
}

auto pushtags(lua_State* const L, std::vector<irctag> const& tags) -> void
{
    lua_createtable(L, 0, tags.size());
    for (auto&& tag : tags)
    {
        push_string(L, tag.key);
        push_string(L, tag.val);
        lua_settable(L, -3);
    }
}

template <>
char const* udata_name<std::weak_ptr<connection>> = "irc_connection";
