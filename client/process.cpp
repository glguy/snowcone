#include "process.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include <boost/asio.hpp>
#include <boost/process.hpp>

#include <memory>
#include <vector>

#include "app.hpp"
#include "safecall.hpp"
#include "strings.hpp"
#include "userdata.hpp"

namespace {

using ExecSig = void(boost::system::error_code, int, std::string, std::string);

class Exec
{
    // Parameters
    boost::asio::io_context& io_context;
    boost::filesystem::path file_;
    std::vector<std::string> args_;

    // Resources
    boost::process::async_pipe stdout_;
    boost::process::async_pipe stderr_;

    // Results
    int stage_;
    boost::system::error_code error_code_;
    int exit_code_;
    std::string stdout_text_;
    std::string stderr_text_;

public:
    struct PipeComplete {};
    struct ExitComplete {};

    Exec(boost::asio::io_context& io_context,
        boost::filesystem::path file,
        std::vector<std::string> args
    )
    : io_context{io_context}
    , file_{std::move(file)}
    , args_{std::move(args)}
    , stdout_{io_context}
    , stderr_{io_context}
    , stage_{0}
    {}

    template <typename Self>
    auto operator()(Self& self) -> void
    {
        auto const self_ = std::make_shared<Self>(std::move(self));
        boost::asio::async_read(
            stdout_,
            boost::asio::dynamic_buffer(stdout_text_),
            [self_](boost::system::error_code const err, std::size_t)
            {
                (*self_)(PipeComplete{}, err);
            });
        boost::asio::async_read(
            stderr_,
            boost::asio::dynamic_buffer(stderr_text_),
            [self_](boost::system::error_code const err, std::size_t)
            {
                (*self_)(PipeComplete{}, err);
            }
        );
        boost::process::async_system(
            io_context,
            [self_](boost::system::error_code const err, int const exit_code)
            {
                (*self_)(ExitComplete{}, err, exit_code);
            },
            boost::process::search_path(file_),
            boost::process::args += std::move(args_),
            boost::process::std_in  < boost::process::null,
            boost::process::std_out > stdout_,
            boost::process::std_err > stderr_);
    }

    // Completion handler for the async_read on the async_pipes
    auto operator()(auto& self, PipeComplete, boost::system::error_code const err) -> void
    {
        step(self, err);
    }

    // Completion handler for async_system
    auto operator()(auto& self, ExitComplete, boost::system::error_code const err, int const exit_code) -> void
    {
        exit_code_ = exit_code;
        step(self, err);
    }

private:
    auto step(auto& self, boost::system::error_code err) -> void {
        if (err) error_code_ = err;
        if (++stage_ == 3) {
            self.complete(error_code_, exit_code_, std::move(stdout_text_), std::move(stderr_text_));
        }
    }
};

template <
boost::asio::completion_token_for<ExecSig> CompletionToken>
auto async_exec(
    boost::asio::io_context& io_context,
    boost::filesystem::path file,
    std::vector<std::string> args,
    CompletionToken&& token)
{
    return boost::asio::async_compose<CompletionToken, ExecSig>(
        Exec{io_context, std::move(file), std::move(args)},
        token, io_context
    );
}

} // namespace

auto l_execute(lua_State* L) -> int
{
    char const* file = luaL_checkstring(L, 1);
    auto const n = luaL_len(L, 2);
    luaL_checkany(L, 3);
    lua_settop(L, 3);

    auto& args = new_object<std::vector<std::string>>(L);
    args.reserve(n);

    for (lua_Integer i = 1; i <= n; i++)
    {
        auto const ty = lua_geti(L, 2, i);
        std::size_t len;
        auto const str = luaL_tolstring(L, -1, &len);
        args.emplace_back(str, len);
        lua_pop(L, 2);
    }

    lua_pushvalue(L, 3);
    auto const cb = luaL_ref(L, LUA_REGISTRYINDEX);

    auto const app = App::from_lua(L);
    async_exec(app->get_executor(), file, std::move(args),
        [L = app->get_lua(), cb](
            boost::system::error_code const err,
            int const exitcode,
            std::string const stdout,
            std::string const stderr)
        {
            // get callback
            lua_rawgeti(L, LUA_REGISTRYINDEX, cb);
            luaL_unref(L, LUA_REGISTRYINDEX, cb);

            lua_pushinteger(L, exitcode);
            push_string(L, stdout);
            push_string(L, stderr);
            safecall(L, "process complete callback", 3);
        }
    );
    return 0;
}
