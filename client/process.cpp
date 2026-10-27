#include "process.hpp"

#include "app.hpp"
#include "boundary.hpp"
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

#include <signal.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace {

/// More than any operating system will accept as an argument list; this only
/// keeps an enormous table from turning into an enormous allocation.
constexpr lua_Integer max_arguments = 65'536;

/// The default limit on each of stdout and stderr
constexpr lua_Integer default_max_output = 16 * 1024 * 1024;

/// Far beyond any real limit; keeps the buffer limit plus one from overflowing
constexpr lua_Integer max_max_output = lua_Integer{1} << 40;

namespace process = boost::process::v2;

/// Process initializer run in the child before exec, after the pipes are on
/// 0-2. It restores the default SIGPIPE action, since main ignores SIGPIPE
/// and an ignored signal stays ignored across exec, and optionally starts a
/// new process group.
///
/// On Linux it also marks every other descriptor close-on-exec. Boost 1.83
/// (Debian trixie) closes only those above the highest it keeps, so the
/// child would inherit the httpd listener and the other pipes; a child that
/// outlives a reload then holds the port. Marking rather than closing keeps
/// the launcher's pipe for reporting a failed exec. Without kernel support
/// (before 5.11) it is left to Boost.
struct ChildSetup
{
    bool group;

    template <typename Launcher, typename Path>
    auto on_exec_setup(Launcher&, Path const&, char const* const*) -> boost::system::error_code
    {
#ifdef CLOSE_RANGE_CLOEXEC
        ::close_range(3, ~0U, CLOSE_RANGE_CLOEXEC);
#endif
        std::signal(SIGPIPE, SIG_DFL);
        if (group && ::setpgid(0, 0) == -1)
        {
            return {errno, boost::system::system_category()};
        }
        return {};
    }
};

/// One child process, owned by its pending operations. While armed, the
/// callback is kept in the registry under this object's address. It is not
/// a LuaRef: the io_context destroys handlers still queued only after
/// lua_close, and that destruction must not touch the state.
struct Exec
{
    lua_State* L; // main thread
    bool armed = true;

    boost::asio::writable_pipe stdin_;
    boost::asio::readable_pipe stdout_;
    boost::asio::readable_pipe stderr_;
    process::process proc_;

    bool group_;
    std::size_t max_output_;

    /// Count number of outstanding async operations.
    int stage_;

    int exit_code_ = -1;
    std::string stdin_text_;
    std::string stdout_text_;
    std::string stderr_text_;

    boost::system::error_code error_code_;
    std::string failure_; // why stop() was called, when not cancelled

    Exec(lua_State* const L, boost::asio::io_context& io_context, std::optional<std::string> input, bool const group, std::size_t const max_output)
        : L{L}
        , stdin_{io_context}
        , stdout_{io_context}
        , stderr_{io_context}
        , proc_{io_context}
        , group_{group}
        , max_output_{max_output}
        , stage_{input ? 4 : 3}
        , stdin_text_{std::move(input).value_or(std::string{})}
    {
    }

    /// Forget the callback, leaving it on the stack when push is set
    auto disarm(lua_State* const L, bool const push) -> void
    {
        if (push)
        {
            lua_rawgetp(L, LUA_REGISTRYINDEX, this);
        }
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, this);
        armed = false;
    }

    /// Kill the child, or its group, and close our ends of the pipes, so
    /// every pending operation finishes soon. The child is signalled only
    /// while it is unreaped (the exit status is stored as it is reaped), so
    /// its pid can't have been reused. A descendant that left the group
    /// keeps running, but we no longer wait on its output.
    auto stop() -> void
    {
        if (proc_.is_open() && process::process_is_running(proc_.native_exit_code()))
        {
            ::kill(group_ ? -proc_.id() : proc_.id(), SIGKILL);
        }
        boost::system::error_code ignored;
        stdin_.close(ignored);
        stdout_.close(ignored);
        stderr_.close(ignored);
    }

    auto fail(std::string message) -> void
    {
        if (failure_.empty())
        {
            failure_ = std::move(message);
        }
        stop();
    }

    auto complete() -> void
    {
        if (--stage_ == 0 && armed)
        {
            disarm(L, true);
            if (not failure_.empty())
            {
                luaL_pushfail(L);
                push_string(L, failure_);
                safecall(L, "process failure callback", 2);
            }
            else if (error_code_)
            {
                luaL_pushfail(L);
                push_string(L, error_code_.what());
                safecall(L, "process failure callback", 2);
            }
            else
            {
                lua_pushinteger(L, exit_code_);
                push_string(L, stdout_text_);
                push_string(L, stderr_text_);
                safecall(L, "process complete callback", 3);
            }
        }
    }

    /// Read one output stream to EOF. The buffer holds one byte more than
    /// the limit: a read that fills it ends without error (EOF would be
    /// one), and means the limit was passed.
    auto read(boost::asio::readable_pipe& pipe, std::string& text, std::shared_ptr<Exec> const& self) -> void
    {
        boost::asio::async_read(
            pipe,
            boost::asio::dynamic_buffer(text, max_output_ + 1),
            [self](boost::system::error_code const ec, std::size_t) {
                if (not ec)
                {
                    self->fail("execute: output exceeded " + std::to_string(self->max_output_) + " bytes");
                }
                self->complete();
            }
        );
    }
};

/// The Lua handle. It doesn't keep the process going: a process runs to the
/// end, or until cancelled, whether or not its handle is collected.
struct Handle
{
    std::weak_ptr<Exec> exec;
};

auto start(std::shared_ptr<Exec> const& self, boost::asio::io_context& io_context, process::filesystem::path file, std::vector<std::string> const& args, bool const has_input) -> void
{
    if (not file.has_parent_path())
    {
        file = process::environment::find_executable(file);
    }

    // The launcher forks and then, in the child, lets the io_context adjust
    // to the fork before exec. An exception from there must not return into
    // a second copy of the client; the parent sees exit status 127.
    auto const parent = ::getpid();
    auto const exit_if_child = [parent] {
        if (::getpid() != parent)
        {
            ::_exit(127);
        }
    };

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
            ChildSetup{self->group_}
        };
    } catch (boost::system::system_error const& e) {
        exit_if_child();
        self->error_code_ = e.code();
        self->stage_ = 1;
        // Not inline: the caller hasn't returned to Lua yet
        boost::asio::post(io_context, [self] { self->complete(); });
        return;
    } catch (...) {
        exit_if_child();
        throw;
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

    self->read(self->stdout_, self->stdout_text_, self);
    self->read(self->stderr_, self->stderr_text_, self);

    self->proc_.async_wait(
        [self](boost::system::error_code const err, int const exit_code) {
            self->error_code_ = err;
            self->exit_code_ = exit_code;
            self->complete();
        }
    );
}

} // namespace

template <>
char const* const udata_name<Handle> = "process";

namespace {

/// The userdata stays reachable after finalization (resurrection, weak-keyed
/// tables), so the payload is emptied rather than destroyed. Collecting the
/// handle doesn't stop the process.
auto l_gc(lua_State* const L) -> int
{
    check_udata<Handle>(L, 1)->exec.reset();
    return 0;
}

/// Drop the callback so it never runs, kill the child (its group when
/// started with group), and stop reading its output. Does nothing once the
/// process has finished or been cancelled.
auto l_cancel(lua_State* const L) -> int
{
    if (auto const exec = check_udata<Handle>(L, 1)->exec.lock())
    {
        if (exec->armed)
        {
            exec->disarm(L, false);
            exec->stop();
        }
    }
    return 0;
}

luaL_Reg const MT[]{
    {"__gc", boundary<l_gc>},
    {}
};

luaL_Reg const Methods[]{
    {"cancel", boundary<l_cancel>},
    {}
};

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

    // 4. options: input, group, max_output
    std::optional<std::string_view> input;
    bool group = false;
    lua_Integer max_output = default_max_output;
    if (not lua_isnoneornil(L, 4))
    {
        luaL_checktype(L, 4, LUA_TTABLE);
        lua_pushnil(L);
        while (lua_next(L, 4))
        {
            auto const key = lua_type(L, -2) == LUA_TSTRING ? std::string_view{lua_tostring(L, -2)} : std::string_view{};
            if (key == "input")
            {
                luaL_argcheck(L, lua_type(L, -1) == LUA_TSTRING, 4, "input must be a string");
                // The table keeps the string alive until it is copied below
                std::size_t len;
                auto const str = lua_tolstring(L, -1, &len);
                input.emplace(str, len);
            }
            else if (key == "group")
            {
                luaL_argcheck(L, lua_type(L, -1) == LUA_TBOOLEAN, 4, "group must be a boolean");
                group = lua_toboolean(L, -1);
            }
            else if (key == "max_output")
            {
                luaL_argcheck(L, lua_isinteger(L, -1), 4, "max_output must be an integer");
                max_output = lua_tointeger(L, -1);
                luaL_argcheck(L, 0 <= max_output && max_output <= max_max_output, 4, "max_output out of range");
            }
            else
            {
                return luaL_argerror(L, 4, "unknown option");
            }
            lua_pop(L, 1);
        }
        // A child in its own group is stopped if it reads the terminal
        luaL_argcheck(L, not group || input, 4, "group needs input");
    }

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

    auto const handle = new_udata<Handle>(L, 0, [L] {
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
        // Keep __gc out of reach of Lua code
        lua_pushboolean(L, false);
        lua_setfield(L, -2, "__metatable");
    });
    std::construct_at(handle);

    auto const app = App::from_lua(L);
    auto const exec = std::make_shared<Exec>(
        app->get_lua(),
        app->get_context(),
        input ? std::optional<std::string>{*input} : std::nullopt,
        group,
        static_cast<std::size_t>(max_output)
    );
    handle->exec = exec;

    // Store the callback
    lua_pushvalue(L, 3);
    lua_rawsetp(L, LUA_REGISTRYINDEX, exec.get());

    start(exec, app->get_context(), file, args, input.has_value());
    return 1;
}
