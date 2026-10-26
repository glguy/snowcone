#include "app.hpp"

#include "applib.hpp"
#include "bracketed_paste.hpp"
#include "myncurses.h"
#include "safecall.hpp"
#include "strings.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <ncurses.h>

// Boost versions with this header let the resolver use more than one thread.
#if __has_include(<boost/asio/config.hpp>)
#include <boost/asio/config.hpp>
#define SNOWCONE_RESOLVER_CONFIG 1
#endif

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <signal.h>
#include <unistd.h>

static char const app_key = '\0';

namespace {

/// False in script mode, where there is no terminal state to restore and
/// escape sequences would only pollute stdout.
bool uses_terminal = true;

/// The names on_signal receives
auto sigabbrev(int const sig) -> char const*
{
    switch (sig)
    {
    case SIGINT: return "SIGINT";
    case SIGTERM: return "SIGTERM";
    case SIGHUP: return "SIGHUP";
    default: return "?";
    }
}

auto restore_terminal() -> void
{
    if (uses_terminal)
    {
        endwin();
        BracketedPaste::disable();
    }
}

/// Panic handler for errors raised outside any protected call. Recovery
/// isn't attempted (out-of-memory is the usual cause); just leave the
/// terminal usable.
auto panic(lua_State* const L) -> int
{
    auto const msg = lua_tostring(L, -1);
    restore_terminal();
    std::fprintf(stderr, "PANIC: unprotected error in call to Lua API (%s)\n",
        msg ? msg : "error object is not a string");
    std::abort();
}

/// Completion handler for top-level coroutines: an exception that escapes
/// one is a bug, so let it propagate out of io_context.run().
auto rethrow(std::exception_ptr const e) -> void
{
    if (e)
    {
        std::rethrow_exception(e);
    }
}

/// Errors that just mean an I/O object was cancelled or closed on purpose.
auto is_stop(boost::system::error_code const& ec) -> bool
{
    return ec == boost::asio::error::operation_aborted
        || ec == boost::asio::error::bad_descriptor;
}

} // namespace

App::App(char const* const filename, bool const headless)
#ifdef SNOWCONE_RESOLVER_CONFIG
    // getaddrinfo blocks, so with the default single resolver thread every
    // lookup in the process queues behind the slowest one. In particular the
    // A and AAAA queries for happy eyeballs would never run in parallel.
    // Older Boost has one resolver thread that can't be configured.
    : io_context{boost::asio::config_from_string{"resolver.threads=4"}}
#else
    : io_context{}
#endif
    , stdin_poll{io_context, STDIN_FILENO}
    , signals{io_context, SIGWINCH, SIGUSR1}
    , main_source{filename}
    , headless{headless}
    , input_running{not headless}
{
    uses_terminal = not headless;
    L = luaL_newstate();
    lua_atpanic(L, panic);
    lua_pushlightuserdata(L, this);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &app_key);
}

/// Handlers still pending may hold Lua references (httpd's LuaRefs, for
/// example), so they are destroyed while Lua is open. Lua's finalizers then
/// destroy their timers, sockets and pipes, which still need the services.
/// Normally nothing is pending: startup() returns only once the event loop
/// has no work, and an exception out of it ends in fatal(), which skips
/// destructors.
App::~App()
{
    io_context.shutdown();
    lua_close(L);
    // stdin is never closed: a closed fd 0 would be reused by the next socket
    // or pipe while ncurses still reads it
    stdin_poll.release();
}

auto App::fatal(std::string_view const message) -> void
{
    restore_terminal();
    std::fprintf(stderr, "snowcone: fatal error: %.*s\n",
        static_cast<int>(message.size()), message.data());
    std::fflush(stderr);
    std::_Exit(EXIT_FAILURE);
}

auto App::from_lua(lua_State* const L) -> App*
{
    lua_rawgetp(L, LUA_REGISTRYINDEX, &app_key);
    auto const a = reinterpret_cast<App*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return a;
}

namespace {

auto do_mouse(lua_State* const L, int const y, int const x, bool const shifted) -> void
{
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    lua_pushboolean(L, shifted);
    lua_callback(L, "on_mouse", 3);
}

auto do_keyboard(lua_State* const L, long const key) -> void
{
    lua_pushinteger(L, key);
    auto const success = lua_callback(L, "on_keyboard", 1);
    // fallback ^C
    if (not success and key == 3)
    {
        raise(SIGINT);
    }
}

auto do_paste(lua_State* const L, std::string_view const paste) -> void
{
    push_string(L, paste);
    lua_callback(L, "on_paste", 1);
}

} // namespace

auto App::resize() -> void
{
    endwin();
    refresh();
    // Setting the size globals can run a __newindex metamethod
    lua_pushcfunction(L, [](lua_State* const L) -> int {
        l_ncurses_resize(L);
        return 0;
    });
    safecall(L, "resize", 0);
    lua_callback(L, "on_resize", 0);
}

/// Signals stay registered after shutdown() so SIGUSR1 can't kill the
/// process, but this loop exits and nothing handles them. A signal_set with
/// no pending wait doesn't keep run() alive.
auto App::signal_thread() -> boost::asio::awaitable<void>
{
    // Caught here rather than by ncurses' handlers, which exit or stop
    // without turning off bracketed paste and focus reporting. Not in
    // script mode, where the defaults are right.
    for (auto const sig : {SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT})
    {
        signals.add(sig);
    }

    // shutdown() may come from inside reload() or on_resize, when no wait is
    // pending for its cancel() to abort
    while (not shutting_down)
    {
        auto const [ec, sig] = co_await signals.async_wait(boost::asio::as_tuple(boost::asio::use_awaitable));
        // A signal queued before shutdown() still completes successfully
        if (shutting_down || is_stop(ec))
        {
            co_return;
        }
        if (ec)
        {
            throw boost::system::system_error{ec};
        }
        switch (sig)
        {
        case SIGUSR1:
            reload();
            break;
        case SIGINT:
        case SIGTERM:
        case SIGHUP:
            terminate_signal(sig);
            break;
        case SIGTSTP:
            suspend();
            break;
        case SIGCONT: // after suspend(), or a SIGSTOP from outside
        case SIGWINCH:
            // While input is stopped a child process may own the tty, so
            // curses must not touch it; start_input() catches up
            if (input_running)
            {
                resize();
            }
            else
            {
                resize_pending = true;
            }
            break;
        }
    }
}

auto App::stdin_thread(unsigned const generation) -> boost::asio::awaitable<void>
{
    std::string paste;
    bool in_paste = false;
    mbstate_t mbstate{};

    // Any callback may stop input or shut down, and a later start_input()
    // makes a new generation; this reader must then not read another key
    auto const live = [this, generation] {
        return not shutting_down && generation == input_generation;
    };

    for (;;)
    {
        auto const [ec] = co_await stdin_poll.async_wait(stdin_poll.wait_read, boost::asio::as_tuple(boost::asio::use_awaitable));
        if (not live() || is_stop(ec))
        {
            co_return;
        }
        if (ec)
        {
            throw boost::system::system_error{ec};
        }
        for (int key; live() && (key = getch(), ERR != key);)
        {
            if (in_paste)
            {
                if (BracketedPaste::end_paste == key)
                {
                    do_paste(L, paste);
                    paste.clear();
                    in_paste = false;
                }
                else
                {
                    paste.push_back(key);
                }
            }
            else if (key == '\x1b')
            {
                key = getch();
                do_keyboard(L, ERR == key ? '\x1b' : -key);
            }
            else if (KEY_MOUSE == key)
            {
                MEVENT ev;
                if (OK == getmouse(&ev) && ev.bstate & BUTTON1_CLICKED)
                {
                    do_mouse(L, ev.y, ev.x, ev.bstate & BUTTON_SHIFT);
                }
            }
            else if (BracketedPaste::start_paste == key)
            {
                in_paste = true;
            }
            else if (BracketedPaste::focus_gained == key)
            {
                do_keyboard(L, -KEY_RESUME);
            }
            else if (BracketedPaste::focus_lost == key)
            {
                do_keyboard(L, -KEY_EXIT);
            }
            else if (key > 0xff)
            {
                do_keyboard(L, -key);
            }
            else if (isascii(key))
            {
                do_keyboard(L, key);
            }
            else
            {
                char const c = key;
                wchar_t code;
                size_t const r = mbrtowc(&code, &c, 1, &mbstate);
                if (r == (size_t)-1)
                {
                    // After EILSEQ the state is unspecified
                    mbstate = {};
                }
                else if (r < (size_t)-2)
                {
                    do_keyboard(L, code);
                }
                continue;
            }

            // Any other key interrupts a partial multibyte sequence
            mbstate = {};
        }
        if (not live())
        {
            co_return;
        }
    }
}

auto App::spawn_reader() -> void
{
    boost::asio::co_spawn(io_context, stdin_thread(++input_generation), rethrow);
}

auto App::start_input() -> void
{
    if (headless || shutting_down || input_running)
    {
        return;
    }
    input_running = true;
    if (started) // otherwise startup() spawns it
    {
        spawn_reader();
    }

    if (resize_pending)
    {
        resize_pending = false;
        // Not inline: the caller is in the middle of a Lua call
        boost::asio::post(io_context, [this] {
            if (input_running && not shutting_down)
            {
                resize();
            }
            else
            {
                resize_pending = true;
            }
        });
    }
}

auto App::stop_input() -> void
{
    if (headless || shutting_down || not input_running)
    {
        return;
    }
    input_running = false;
    ++input_generation;
    boost::system::error_code ignored;
    stdin_poll.cancel(ignored);
    endwin();
}

/// Runs until the event loop has no work left. Interactive mode always has
/// work until shutdown(); a script ends once its last resource finishes.
/// SIGINT, SIGTERM or SIGHUP: Lua's, if it asked for them. Otherwise, as
/// ncurses' handler did, restore the terminal and take the default action.
/// While a child has the terminal, a ^C there was meant for the child.
auto App::terminate_signal(int const sig) -> void
{
    if (sig == SIGINT && not input_running)
    {
        return;
    }
    if (catch_signals)
    {
        lua_pushstring(L, sigabbrev(sig));
        lua_callback(L, "on_signal", 1);
        return;
    }
    restore_terminal();
    boost::system::error_code ignored;
    signals.remove(sig, ignored);
    ::raise(sig);
}

/// Stop as a shell's ^Z would: the whole process group stops. The terminal
/// is put back first, and on resume SIGCONT redraws. Without curses (a
/// child has the terminal) this only stops.
auto App::suspend() -> void
{
    if (input_running)
    {
        endwin();
        BracketedPaste::disable();
    }
    boost::system::error_code ignored;
    signals.remove(SIGTSTP, ignored);
    ::kill(0, SIGTSTP); // returns once continued
    signals.add(SIGTSTP, ignored);
    if (input_running)
    {
        BracketedPaste::enable();
    }
}

auto App::startup() -> void
{
    // Input stays off if the script stopped it while loading, for example to
    // run a command on the tty
    if (not headless && not shutting_down)
    {
        started = true;
        if (input_running)
        {
            spawn_reader();
        }
        boost::asio::co_spawn(io_context, signal_thread(), rethrow);
    }
    io_context.run();
}

/// Stop input and signal handling for good, and restore the terminal.
/// Pending waits are cancelled, and each coroutine also checks the flag,
/// which covers a coroutine that isn't waiting right now (the caller may be
/// one of its callbacks).
auto App::shutdown() -> void
{
    shutting_down = true;
    input_running = false;
    boost::system::error_code ignored;
    stdin_poll.cancel(ignored);
    signals.cancel(ignored);
    // Whatever still runs, ^C at the restored terminal now ends the process
    for (auto const sig : {SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT})
    {
        signals.remove(sig, ignored);
    }
    restore_terminal();
}

auto App::reload() -> bool
{
    auto const r = luaL_loadfile(L, main_source);
    if (LUA_OK == r)
    {
        safecall(L, "reload", 0);
        return true;
    }
    else
    {
        auto const err = lua_tolstring(L, -1, nullptr);
        endwin();
        std::cerr << "error in reload:load: " << err << std::endl;
        lua_pop(L, 1);
        return false;
    }
}
