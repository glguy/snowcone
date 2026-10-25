#include "process.hpp"

#include "app.hpp"
#include "boundary.hpp"
#include "safecall.hpp"
#include "strings.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <boost/asio.hpp>
#include <boost/process/v2/process.hpp>
#include <boost/process/v2/stdio.hpp>
#include <boost/process/v2/environment.hpp>

#include <csignal>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {

/// More than any operating system will accept as an argument list; this only
/// keeps an enormous table from turning into an enormous allocation.
constexpr lua_Integer max_arguments = 65'536;

/// @brief Signature for the process execution completion handler.
/// @param error Error code indicating process or I/O failure (if any).
/// @param exit_code Exit code returned by the process.
/// @param stdout_text Captured standard output from the process.
/// @param stderr_text Captured standard error from the process.
using ExecSig = void(boost::system::error_code error, int exit_code, std::string stdout_text, std::string stderr_text);

namespace process = boost::process::v2;

/// Process initializer that restores the default SIGPIPE action in the child.
/// main ignores SIGPIPE, and an ignored signal stays ignored across exec.
struct DefaultSigpipe
{
    template <typename Launcher, typename Path>
    auto on_exec_setup(Launcher&, Path const&, char const* const*) -> boost::system::error_code
    {
        std::signal(SIGPIPE, SIG_DFL);
        return {};
    }
};

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

    int exit_code_ = -1;
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
                                process::filesystem::path file,
                                std::vector<std::string> args,
                                std::optional<std::string> input
                            ) -> void {
    auto const has_input = input.has_value();
    auto const self = std::make_shared<Exec<Handler>>(std::forward<Handler>(handler), io_context, std::move(input));

    if (not file.has_parent_path())
    {
        file = process::environment::find_executable(file);
    }
 
    try {
        using in_t = decltype(process::process_stdio::in);
        self->proc_ = process::process{
            io_context,
            file,
            args,
            process::process_stdio{
                .in = has_input ? in_t{self->stdin_} : in_t{},
                .out = {self->stdout_},
                .err = {self->stderr_},
            },
            DefaultSigpipe{}
        };
    } catch (boost::system::system_error const& e) {
        self->error_code_ = e.code();
        self->stage_ = 1;
        // Not inline: the caller hasn't returned to Lua yet
        boost::asio::post(io_context, [self] { self->complete(); });
        return;
    }

    if (has_input)
    {
        boost::asio::async_write(
            self->stdin_,
            boost::asio::buffer(self->stdin_text_),
            [self](boost::system::error_code, std::size_t) {
                boost::system::error_code ec; // ignored
                self->stdin_.close(ec);
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
    process::filesystem::path file,
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

auto l_execute(lua_State* const L) -> int
{
    // Validate everything with raw access before any C++ object exists, so
    // nothing below can raise while the argument vector is live.

    // 1. Path to executable
    auto const file = check_c_string(L, 1);

    // 2. array of command arguments: strings, or numbers, as luaL_checkstring
    // accepts. Callers convert anything else with tostring themselves.
    luaL_checktype(L, 2, LUA_TTABLE);
    auto const n = static_cast<lua_Integer>(lua_rawlen(L, 2));
    luaL_argcheck(L, n <= max_arguments, 2, "too many arguments");
    for (lua_Integer i = 1; i <= n; i++)
    {
        auto const type = lua_rawgeti(L, 2, i);
        if (type != LUA_TSTRING && type != LUA_TNUMBER)
        {
            return luaL_error(L, "execute: argument %d is a %s, not a string", static_cast<int>(i), luaL_typename(L, -1));
        }
        std::size_t len;
        auto const str = lua_tolstring(L, -1, &len); // converts only this copy
        if (has_nul({str, len}))
        {
            return luaL_error(L, "execute: argument %d contains a NUL byte", static_cast<int>(i));
        }
        lua_pop(L, 1);
    }

    // 3. completion handler
    luaL_checkany(L, 3);

    // 4. optional stdin string
    auto const input = opt_string_view(L, 4);

    std::vector<std::string> args;
    args.reserve(n);
    for (lua_Integer i = 1; i <= n; i++)
    {
        lua_rawgeti(L, 2, i);
        std::size_t len;
        auto const str = lua_tolstring(L, -1, &len);
        args.emplace_back(str, len);
        lua_pop(L, 1);
    }

    lua_pushvalue(L, 3);
    auto const cb = luaL_ref(L, LUA_REGISTRYINDEX);

    auto const app = App::from_lua(L);

    async_exec(
        app->get_context(),
        file,
        std::move(args),
        input ? std::optional<std::string>{*input} : std::nullopt,
        [L = app->get_lua(), cb](
            boost::system::error_code const err,
            int const exitcode,
            std::string const stdout_text,
            std::string const stderr_text
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
                push_string(L, stdout_text);
                push_string(L, stderr_text);
                safecall(L, "process complete callback", 3);
            }
        }
    );

    lua_pushboolean(L, true);
    return 1;
}
