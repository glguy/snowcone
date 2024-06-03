#include "process.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "strings.hpp"
#include "userdata.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <boost/asio.hpp>
#include <boost/process.hpp>

#include <memory>
#include <optional>
#include <vector>

namespace {

using ExecSig = void(int, std::string, std::string);

template <boost::asio::completion_handler_for<ExecSig> Handler>
struct Exec
{
    Handler handler_;
    boost::process::async_pipe stdin_;
    boost::process::async_pipe stdout_;
    boost::process::async_pipe stderr_;

    int stage_;

    int exit_code_;
    std::string stdin_text_;
    std::string stdout_text_;
    std::string stderr_text_;

    Exec(Handler&& handler, boost::asio::io_context& io_context, std::optional<std::string> input)
        : handler_{std::move(handler)}
        , stdin_{io_context}
        , stdout_{io_context}
        , stderr_{io_context}
        , stage_{input ? 0 : 1}
        , stdin_text_{input ? std::move(*input) : ""}
    {
    }

    auto operator()(boost::system::error_code err, std::size_t) -> void
    {
        complete();
    }

    auto complete() -> void
    {
        if (++stage_ == 4)
        {
            handler_(exit_code_, std::move(stdout_text_), std::move(stderr_text_));
        }
    }
};

// N.B. This is a lambda so that template argument inference
// is delayed until function application and not when passed
// to async_initiate.
constexpr auto initiation = []<boost::asio::completion_handler_for<ExecSig> Handler>(
                                Handler&& handler,
                                boost::asio::io_context& io_context,
                                boost::filesystem::path file,
                                std::vector<std::string> args,
                                std::optional<std::string> input
                            ) -> void {
    auto const has_input = input.has_value();
    auto const self = std::make_shared<Exec<Handler>>(std::forward<Handler>(handler), io_context, std::move(input));

    if (has_input)
    {
        boost::asio::async_write(
            self->stdin_,
            boost::asio::buffer(self->stdin_text_),
            [self](boost::system::error_code, std::size_t) {
                self->stdin_.close();
                self->complete();
            }
        );
    }

    boost::asio::async_read(
        self->stdout_,
        boost::asio::dynamic_buffer(self->stdout_text_),
        [self](boost::system::error_code, std::size_t) {
            self->complete();
        }
    );
    boost::asio::async_read(
        self->stderr_,
        boost::asio::dynamic_buffer(self->stderr_text_),
        [self](boost::system::error_code, std::size_t) {
            self->complete();
        }
    );
    auto const completion =
        [self](boost::system::error_code, int const exit_code) {
            self->exit_code_ = exit_code;
            self->complete();
        };

    if (has_input)
    {
        boost::process::async_system(
            io_context,
            completion,
            boost::process::search_path(file),
            boost::process::args += std::move(args),
            boost::process::std_in  < self->stdin_,
            boost::process::std_out > self->stdout_,
            boost::process::std_err > self->stderr_
        );
    }
    else
    {
        boost::process::async_system(
            io_context,
            completion,
            boost::process::search_path(file),
            boost::process::args += std::move(args),
            boost::process::std_out > self->stdout_,
            boost::process::std_err > self->stderr_
        );
    }
};

template <
    boost::asio::completion_token_for<ExecSig> CompletionToken>
auto async_exec(
    boost::asio::io_context& io_context,
    boost::filesystem::path file,
    std::vector<std::string> args,
    std::optional<std::string> input,
    CompletionToken&& token
)
{
    return boost::asio::async_initiate<CompletionToken, ExecSig>(
        initiation, token, io_context, std::move(file), std::move(args), std::move(input)
    );
}

} // namespace

auto l_execute(lua_State* L) -> int
{
    auto const file = check_string_view(L, 1);
    auto const n = luaL_len(L, 2);
    luaL_checkany(L, 3);
    std::size_t input_len;
    auto const input_ptr = luaL_optlstring(L, 4, nullptr, &input_len);
    std::optional<std::string> input
        = input_ptr == nullptr
        ? std::optional<std::string>{}
        : std::optional<std::string>{{input_ptr, input_len}};

    auto& args = new_object<std::vector<std::string>>(L);
    args.reserve(n);

    for (lua_Integer i = 1; i <= n; i++)
    {
        lua_geti(L, 2, i);
        std::size_t len;
        auto const str = luaL_tolstring(L, -1, &len);
        args.emplace_back(str, len);
        lua_pop(L, 2);
    }

    lua_pushvalue(L, 3);
    auto const cb = luaL_ref(L, LUA_REGISTRYINDEX);
    auto const app = App::from_lua(L);
    async_exec(app->get_executor(), file, std::move(args), std::move(input), [L = app->get_lua(), cb](int const exitcode, std::string const stdout, std::string const stderr) {
        // get callback
        lua_rawgeti(L, LUA_REGISTRYINDEX, cb);
        luaL_unref(L, LUA_REGISTRYINDEX, cb);

        lua_pushinteger(L, exitcode);
        push_string(L, stdout);
        push_string(L, stderr);
        safecall(L, "process complete callback", 3);
    });
    return 0;
}
