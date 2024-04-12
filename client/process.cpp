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

template <boost::asio::completion_handler_for<ExecSig> Handler>
struct Exec
{
    Handler handler_;
    boost::process::async_pipe stdout_;
    boost::process::async_pipe stderr_;

    int stage_;
    boost::system::error_code error_code_;

    int exit_code_;
    std::string stdout_text_;
    std::string stderr_text_;

    Exec(Handler&& handler, boost::asio::io_context& io_context)
    : handler_{std::move(handler)}
    , stdout_{io_context}
    , stderr_{io_context}
    , stage_{0}
    {}

    auto operator()(boost::system::error_code err, std::size_t) -> void
    {
        complete(err);
    }

    auto complete(boost::system::error_code err) -> void {
        if (err) error_code_ = err;
        if (++stage_ == 3) {
            handler_(error_code_, exit_code_, std::move(stdout_text_), std::move(stderr_text_));
        }
    }
};

// N.B. This is a lambda so that template argument inference
// is delayed until function application and not when passed
// to async_initiate.
constexpr auto initiation = []
<boost::asio::completion_handler_for<ExecSig> Handler>
(
    Handler&& handler,
    boost::asio::io_context& io_context,
    boost::filesystem::path file,
    std::vector<std::string> args
) -> void
{
    auto const self = std::make_shared<Exec<Handler>>(std::move(handler), io_context);
    boost::asio::async_read(
        self->stdout_,
        boost::asio::dynamic_buffer(self->stdout_text_),
        [self](boost::system::error_code err, std::size_t)
        {
            self->complete(err);
        }
    );
    boost::asio::async_read(
        self->stderr_,
        boost::asio::dynamic_buffer(self->stderr_text_),
        [self](boost::system::error_code err, std::size_t)
        {
            self->complete(err);
        }
    );
    boost::process::async_system(
        io_context,
        [self](boost::system::error_code err, int exit_code)
        {
            self->exit_code_ = exit_code;
            self->complete(err);
        },
        boost::process::search_path(file),
        boost::process::args += std::move(args),
        boost::process::std_in  < boost::process::null,
        boost::process::std_out > self->stdout_,
        boost::process::std_err > self->stderr_
    );
};

template <
    boost::asio::completion_token_for<ExecSig> CompletionToken>
auto async_exec(
    boost::asio::io_context& io_context,
    boost::filesystem::path file,
    std::vector<std::string> args,
    CompletionToken&& token)
{
    return boost::asio::async_initiate<CompletionToken, ExecSig>(
        initiation, token, io_context, std::move(file), std::move(args)
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
