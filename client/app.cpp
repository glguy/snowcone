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

#include <clocale>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <signal.h>
#include <unistd.h>

static char const app_key = '\0';

namespace {

/// Set by start_ui(). Until then there is no terminal state to restore, and
/// escape sequences would only pollute stdout.
bool uses_terminal = false;

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
    std::size_t len;
    auto const msg = lua_tolstring(L, -1, &len);
    restore_terminal();
    std::fputs("PANIC: unprotected error in call to Lua API (", stderr);
    write_escaped(stderr, msg ? std::string_view{msg, len} : "error object is not a string");
    std::fputs(")\n", stderr);
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

App::App(char const* const filename)
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
    , signals{io_context}
    , main_source{filename}
{
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
    restore_terminal();
    // stdin is never closed: a closed fd 0 would be reused by the next socket
    // or pipe while ncurses still reads it
    stdin_poll.release();
}

auto App::fatal(std::string_view const message) -> void
{
    restore_terminal();
    std::fputs("snowcone: fatal error: ", stderr);
    write_escaped(stderr, message);
    std::fputc('\n', stderr);
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

/// A paste over the limit is dropped whole: on_paste(nil, size)
auto do_paste_discarded(lua_State* const L, std::size_t const size) -> void
{
    lua_pushnil(L);
    lua_pushinteger(L, static_cast<lua_Integer>(size));
    lua_callback(L, "on_paste", 2);
}

/// The most pasted text delivered; a larger paste is most likely a mistake
constexpr std::size_t max_paste = 64 * 1024;

/// Ends a bracketed paste. Pastes are read with keypad mode off, so the
/// marker is found in the raw bytes however it was split in transit, and
/// pasted escape sequences arrive intact. Terminals keep it out of pasted
/// text.
constexpr std::string_view end_paste_marker = "\x1b[201~";

/// Keypad mode is off while a paste is read; this turns it back on however
/// the reader ends, so the next reader decodes keys again.
struct PasteMode
{
    bool on = false;
    std::string text; // the paste so far, then only a tail once discarding
    std::size_t size = 0; // bytes received, the end marker included
    bool discarding = false;

    auto start() -> void
    {
        on = true;
        keypad(stdscr, FALSE);
    }

    auto stop() -> void
    {
        on = false;
        text.clear();
        size = 0;
        discarding = false;
        keypad(stdscr, TRUE);
    }

    ~PasteMode()
    {
        if (on)
        {
            keypad(stdscr, TRUE);
        }
    }

    /// Add one byte; true once the end marker has arrived
    auto add(char const c) -> bool
    {
        text.push_back(c);
        ++size;
        if (text.ends_with(end_paste_marker))
        {
            text.resize(text.size() - end_paste_marker.size());
            return true;
        }
        // Past the limit only a tail that may hold the start of the marker
        // is kept
        if (text.size() > max_paste + end_paste_marker.size())
        {
            discarding = true;
        }
        if (discarding && text.size() >= end_paste_marker.size())
        {
            text.erase(0, text.size() - (end_paste_marker.size() - 1));
        }
        return false;
    }
};

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
    // without turning off bracketed paste and focus reporting. Without a UI
    // the defaults are right, so this starts with it.
    for (auto const sig : {SIGWINCH, SIGUSR1, SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT})
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
    PasteMode paste;
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
            if (paste.on)
            {
                // Keypad mode is off, so anything above a byte (KEY_RESIZE)
                // didn't come from the terminal
                if (key <= 0xff && paste.add(static_cast<char>(key)))
                {
                    if (paste.discarding)
                    {
                        auto const size = paste.size - end_paste_marker.size();
                        paste.stop();
                        do_paste_discarded(L, size);
                    }
                    else
                    {
                        auto const text = std::move(paste.text);
                        paste.stop();
                        do_paste(L, text);
                    }
                }
            }
            else if (key == '\x1b')
            {
                key = getch();
                if (BracketedPaste::start_paste == key || BracketedPaste::focus_gained == key ||
                    BracketedPaste::focus_lost == key || KEY_MOUSE == key)
                {
                    // Not Alt-modified: a plain Esc, then the event as usual
                    ungetch(key);
                    do_keyboard(L, '\x1b');
                }
                else
                {
                    do_keyboard(L, ERR == key ? '\x1b' : -key);
                }
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
                paste.start();
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
    if (not ui || shutting_down || input_running)
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
    if (not ui || shutting_down || not input_running)
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
    started = true;
    if (ui && not shutting_down)
    {
        spawn_ui();
    }
    io_context.run();
}

/// The UI's coroutines. Input stays off if the program stopped it while
/// loading, for example to run a command on the tty.
auto App::spawn_ui() -> void
{
    if (input_running)
    {
        spawn_reader();
    }
    boost::asio::co_spawn(io_context, signal_thread(), rethrow);
}

auto App::start_ui() -> void
{
    if (ui || shutting_down)
    {
        return;
    }
    ui = true;
    uses_terminal = true;
    input_running = true;

    setlocale(LC_ALL, "");
    initscr();
    start_color();
    use_default_colors();
    raw(); // pass through all the keys
    noecho(); // no echo input to screen
    nonl(); // no newline on pressing return
    curs_set(0); // no cursor
    mousemask(BUTTON1_CLICKED | BUTTON_SHIFT, nullptr);
    set_escdelay(25);
    nodelay(stdscr, TRUE); // nonblocking input reads
    intrflush(stdscr, FALSE);
    keypad(stdscr, TRUE); // process keyboard input escape sequences
    BracketedPaste::install();
    BracketedPaste::enable();

    if (started) // otherwise startup() spawns them
    {
        spawn_ui();
    }
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
        std::size_t len;
        auto const err = lua_tolstring(L, -1, &len);
        endwin();
        std::fputs("error in reload:load: ", stderr);
        write_escaped(stderr, {err, len});
        std::fputc('\n', stderr);
        lua_pop(L, 1);
        return false;
    }
}
