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
#include <boost/process/v2/process.hpp>
#include <boost/process/v2/stdio.hpp>
#include <boost/process/v2/environment.hpp>

#include <memory>
#include <optional>
#include <vector>

namespace {

/// @brief Signature for the process execution completion handler.
/// @param error Error code indicating process or I/O failure (if any).
/// @param exit_code Exit code returned by the process.
/// @param stdout_text Captured standard output from the process.
/// @param stderr_text Captured standard error from the process.
using ExecSig = void(boost::system::error_code error, int exit_code, std::string stdout_text, std::string stderr_text);

namespace process = boost::process::v2;

template <boost::asio::completion_handler_for<ExecSig> Handler>
struct Exec
{
    Handler handler_;
    boost::asio::writable_pipe stdin_;
    boost::asio::readable_pipe stdout_;
    boost::asio::readable_pipe stderr_;
    process::process proc_;

    /// Count number of outstanding async operations.
    int stage_;

    int exit_code_;
    std::string stdin_text_;
    std::string stdout_text_;
    std::string stderr_text_;

    boost::system::error_code error_code_;

    Exec(Handler&& handler, boost::asio::io_context& io_context, std::optional<std::string> input)
        : handler_{std::move(handler)}
        , stdin_{io_context}
        , stdout_{io_context}
        , stderr_{io_context}
        , proc_{io_context}
        , stage_{input ? 4 : 3}
        , stdin_text_{std::move(input).value_or(std::string{})}
    {
    }

    auto complete() -> void
    {
        if (--stage_ == 0)
        {
            handler_(error_code_, exit_code_, std::move(stdout_text_), std::move(stderr_text_));
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

    if (not file.has_parent_path())
    {
        file = process::environment::find_executable(file);
    }
 
    decltype(process::process_stdio::in) stdin_binding;
    if (has_input) stdin_binding = {self->stdin_};

    self->proc_ = process::process{
        io_context,
        file,
        args,
        process::process_stdio{
            .in = std::move(stdin_binding),
            .out = {self->stdout_},
            .err = {self->stderr_},
        }
    };

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

    self->proc_.async_wait(
        [self](boost::system::error_code const err, int const exit_code) {
            self->error_code_ = err;
            self->exit_code_ = exit_code;
            self->complete();
        }
    );
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
    // 1. Path to executable
    auto const file = check_string_view(L, 1);

    // 2. array of command arguments
    auto const n = luaL_len(L, 2);
    
    // 3. completion handler
    luaL_checkany(L, 3);

    // 4. optional stdin string
    std::size_t input_len;
    auto const input_ptr = luaL_optlstring(L, 4, nullptr, &input_len);
    
    // new_object used to avoid putting objects with destructors
    // onto the stack in case the lua functions below fail.
    auto& input = new_object<std::optional<std::string>>(L);
    auto& args = new_object<std::vector<std::string>>(L);

    if (input_ptr) {
        input.emplace(input_ptr, input_len);
    }

    args.reserve(n);
    for (lua_Integer i = 1; i <= n; i++)
    {
        lua_geti(L, 2, i);
        std::size_t len;
        auto const str = luaL_tolstring(L, -1, &len);
        args.emplace_back(str, len);
        lua_pop(L, 2); // pops array element and string representation
    }

    lua_pushvalue(L, 3);
    auto const cb = luaL_ref(L, LUA_REGISTRYINDEX);

    auto const app = App::from_lua(L);
    async_exec(
        app->get_context(),
        file,
        std::move(args),
        std::move(input),
        [L = app->get_lua(), cb](
            boost::system::error_code const err,
            int const exitcode,
            std::string const stdout,
            std::string const stderr
        ) {
            // get callback
            lua_rawgeti(L, LUA_REGISTRYINDEX, cb);
            luaL_unref(L, LUA_REGISTRYINDEX, cb);

            if (err)
            {
                luaL_pushfail(L);
                push_string(L, err.what());
                safecall(L, "process failure callback", 2);
            }
            else
            {
                lua_pushinteger(L, exitcode);
                push_string(L, stdout);
                push_string(L, stderr);
                safecall(L, "process complete callback", 3);
            }
        }
    );
    return 0;
}
