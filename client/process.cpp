#include "process.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include <boost/asio.hpp>
#include <boost/process.hpp>

#include <cstring>
#include <cstdlib>
#include <memory>
#include <vector>

#include "app.hpp"
#include "safecall.hpp"
#include "strings.hpp"

struct Process : public std::enable_shared_from_this<Process>
{
    Process(App & app)
    : app_{app}
    , stdout_{app.io_context}
    , stderr_{app.io_context}
    , completions_{0}
    {}

    auto start(char const* file, std::vector<std::string> args) -> void
    {
        read_loop(stdout_, stdout_txt_);
        read_loop(stderr_, stderr_txt_);
        boost::process::async_system(
            app_.io_context,
            [self = shared_from_this()](boost::system::error_code, int exitcode) {
                self->exitcode_ = exitcode;
                self->complete();
            },
        boost::process::search_path(file),
        boost::process::args += args,
        boost::process::std_in  < boost::process::null,
        boost::process::std_out > stdout_,
        boost::process::std_err > stderr_);
    }

private:
    auto complete() -> void
    {
        completions_++;
        if (completions_ == 3){
            // get callback
            lua_rawgetp(app_.L, LUA_REGISTRYINDEX, this);
            // forget callback
            lua_pushnil(app_.L);
            lua_rawsetp(app_.L, LUA_REGISTRYINDEX, this);

            lua_pushinteger(app_.L, exitcode_);
            push_string(app_.L, stdout_txt_);
            push_string(app_.L, stderr_txt_);
            safecall(app_.L, "process complete callback", 3);
        }
    }

    auto read_loop(boost::process::async_pipe& pipe, std::string& buf) -> void
    {
        boost::asio::async_read(
            pipe,
            boost::asio::dynamic_buffer(buf),
            [self = shared_from_this()](boost::system::error_code, std::size_t)
            {
                self->complete();
            }
        );
    }

    App& app_;
    boost::process::async_pipe stdout_;
    boost::process::async_pipe stderr_;
    int completions_;

    std::string stdout_txt_;
    std::string stderr_txt_;
    int exitcode_;
};

auto l_execute(lua_State* L) -> int
{
    char const* file = lua_tostring(L, 1);

    if (file == nullptr)
    {
        luaL_pushfail(L);
        lua_pushstring(L, "bad file");
        return 2;
    }

    auto const n = lua_rawlen(L, 2);
    std::vector<std::string> args;
    args.reserve(n);

    for (int i = 1; i <= n; i++)
    {
        auto const ty = lua_rawgeti(L, 2, i);
        if (ty != LUA_TSTRING) {
            luaL_pushfail(L);
            lua_pushstring(L, "bad argument");
            return 2;
        }
        args.push_back(lua_tostring(L, -1));
        lua_pop(L, 1);
    }

    auto const process = std::make_shared<Process>(*App::from_lua(L));

    lua_pushvalue(L, 3);
    lua_rawsetp(L, LUA_REGISTRYINDEX, process.get());

    process->start(file, std::move(args));

    lua_pushboolean(L, true);
    return 1;
}
