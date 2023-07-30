#include "irc.hpp"

#include "app.hpp"
#include "read-line.hpp"
#include "safecall.hpp"
#include "socat.hpp"
#include "uv.hpp"

#include <ircmsg.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <uv.h>


#include <charconv> // from_chars
#include <sstream>
#include <string>

namespace
{
    /**
     * @brief Push string_view value onto Lua stack
     *
     * @param L Lua
     * @param str string
     * @return char const* string in Lua memory
     */
    auto push_stringview(lua_State * const L, std::string_view const str) -> char const *
    {
        return lua_pushlstring(L, str.data(), str.size());
    }

    auto pushircmsg(lua_State * const L, ircmsg const &msg) -> void
    {
        lua_createtable(L, msg.args.size(), 3);

        lua_createtable(L, 0, msg.tags.size());
        for (auto &&tag : msg.tags)
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

    class R final
    {
        uv_write_t write;
        lua_State *const L;
        int const ref;

    public:
        R(lua_State *L, int ref) : L{L}, ref{ref}
        {
            write.data = this;
        }
        ~R()
        {
            luaL_unref(L, LUA_REGISTRYINDEX, ref);
        }
        uv_write_t *to_write()
        {
            return &write;
        }
        static R *from_write(uv_write_t const *write)
        {
            return static_cast<R *>(write->data);
        }
    };

    auto on_send_irc(lua_State *L) -> int
    {
        auto const stream = reinterpret_cast<uv_stream_t *>(lua_touserdata(L, lua_upvalueindex(1)));
        if (stream == nullptr)
        {
            luaL_error(L, "send to closed irc");
            return 0;
        }

        size_t n;
        auto const cmd = luaL_optlstring(L, 1, nullptr, &n);
        lua_settop(L, 1);

        if (cmd == nullptr)
        {
            auto shutdown = std::make_unique<uv_shutdown_t>();
            uvok(uv_shutdown(shutdown.get(), stream, [](uv_shutdown_t *req, auto stat)
                             { delete req; }));
            shutdown.release();
        }
        else
        {
            auto const ref = luaL_ref(L, LUA_REGISTRYINDEX);
            auto const buf = uv_buf_init(const_cast<char *>(cmd), n);
            auto req = std::make_unique<R>(L, ref);
            uvok(uv_write(req->to_write(), stream, &buf, 1,
                          [](uv_write_t *write, int status)
                          {
                              delete R::from_write(write);
                          }));
            req.release();
        }

        return 0;
    }
}

auto start_irc(lua_State *const L) -> int
{
    auto const a = App::from_lua(L);

    auto const arg = luaL_checklstring(L, 1, nullptr);
    luaL_checkany(L, 2);
    lua_settop(L, 2);

    try
    {
        auto [irc, err] = socat_wrapper(&a->loop, arg);
        auto delete_pipe = [](uv_handle_t *h)
        { delete reinterpret_cast<uv_pipe_t *>(h); };

        lua_pushvalue(L, 2);
        auto const irc_err_cb = luaL_ref(L, LUA_REGISTRYINDEX);

        lua_pushvalue(L, 2);
        auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);

        // index 3
        lua_pushlightuserdata(L, irc.get());
        lua_pushcclosure(L, on_send_irc, 1);

        lua_pushvalue(L, 3);
        auto const send_cb = luaL_ref(L, LUA_REGISTRYINDEX);

        // XXX These don't get cleaned up if one of the readlines fails!

        readline_start(
            stream_cast(err.get()),
            [L, irc_err_cb](char *line)
            {
                lua_rawgeti(L, LUA_REGISTRYINDEX, irc_err_cb);
                lua_pushnil(L);
                lua_pushstring(L, line);
                safecall(L, "irc_err:on_line", 2); },
            [L, irc_err_cb](ssize_t err)
            {
                luaL_unref(L, LUA_REGISTRYINDEX, irc_err_cb);
            },
            delete_pipe);
        err.release();

        readline_start(
            stream_cast(irc.get()),
            [L, irc_cb](char *line)
            {
                while (*line == ' ')
                {
                    line++;
                }
                if (*line == '\0')
                {
                    return;
                }

                try
                {
                    auto const msg = parse_irc_message(line); // might throw
                    lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                    pushircmsg(L, msg);
                    safecall(L, "on_irc_line", 1);
                }
                catch (irc_parse_error const &e)
                {
                    std::stringstream msg;
                    msg << "parse_irc_message failed: " << e.code;

                    lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                    lua_pushnil(L);
                    lua_pushlstring(L, msg.str().data(), msg.str().size());
                    safecall(L, "on_irc_line", 2);
                }
            },
            [L, irc_cb, send_cb](ssize_t err)
            {
                // clear out send_irc's pointer to the uv_pipe
                lua_rawgeti(L, LUA_REGISTRYINDEX, send_cb);
                lua_pushnil(L);
                lua_setupvalue(L, -2, 1);
                lua_pop(L, 1);

                // on_irc()
                lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                safecall(L, "on_irc_done", 0);

                // forget lua values
                luaL_unref(L, LUA_REGISTRYINDEX, irc_cb);
                luaL_unref(L, LUA_REGISTRYINDEX, send_cb);
            },
            delete_pipe);
        irc.release();

        return 1; // returns the on_send callback function
    }
    catch (UV_error const &e)
    {
        std::stringstream msg;
        msg << "socat spawn failed: " << e.what();
        return 0;
    }
}
