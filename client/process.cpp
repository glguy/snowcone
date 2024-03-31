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

namespace {

using ExecSig = void(boost::system::error_code, int, std::string, std::string);

template <boost::asio::completion_handler_for<ExecSig> Handler>
class Exec : public std::enable_shared_from_this<Exec<Handler>>
{
    Handler handler_;
    boost::process::async_pipe stdout_;
    boost::process::async_pipe stderr_;

    int stage_ = 0;

    boost::system::error_code error_code_;
    int exit_code_;
    std::string stdout_text_;
    std::string stderr_text_;

public:
    Exec(Handler&& handler, boost::asio::io_context& io_context)
    : handler_{handler}
    , stdout_{io_context}
    , stderr_{io_context}
    {}

    auto start(
        boost::asio::io_context& io_context,
        boost::filesystem::path file,
        std::vector<std::string> args
    ) -> void
    {
        boost::asio::async_read(
            stdout_,
            boost::asio::dynamic_buffer(stdout_text_),
            [self = this->shared_from_this()](boost::system::error_code err, std::size_t)
            {
                self->complete(err);
            }
        );
        boost::asio::async_read(
            stderr_,
            boost::asio::dynamic_buffer(stderr_text_),
            [self = this->shared_from_this()](boost::system::error_code err, std::size_t)
            {
                self->complete(err);
            }
        );
        boost::process::async_system(
            io_context,
            [self = this->shared_from_this()](boost::system::error_code err, int exit_code)
            {
                self->exit_code_ = exit_code;
                self->complete(err);
            },
            boost::process::search_path(file),
            boost::process::args += std::move(args),
            boost::process::std_in  < boost::process::null,
            boost::process::std_out > stdout_,
            boost::process::std_err > stderr_);
    }

private:
    auto complete(boost::system::error_code err) -> void {
        if (err) error_code_ = err;
        if (++stage_ == 3) {
            handler_(error_code_, exit_code_, std::move(stdout_text_), std::move(stderr_text_));
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
    return boost::asio::async_initiate<CompletionToken, ExecSig>(
        [](
            boost::asio::completion_handler_for<ExecSig> auto handler,
            boost::asio::io_context& io_context,
            boost::filesystem::path file,
            std::vector<std::string> args)
        {
            std::make_shared<Exec<decltype(handler)>>(std::move(handler), io_context)
            ->start(io_context, file, std::move(args));
        },
        token, io_context, std::move(file), std::move(args)
    );
}

}

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
        args.emplace_back(lua_tostring(L, -1));
        lua_pop(L, 1);
    }

    lua_pushvalue(L, 3);
    auto const cb = luaL_ref(L, LUA_REGISTRYINDEX);

    async_exec(App::from_lua(L)->get_executor(), file, std::move(args),
        [L, cb](boost::system::error_code err, int exitcode, std::string stdout, std::string stderr)
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

    lua_pushboolean(L, true);
    return 1;
}
