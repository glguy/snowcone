#pragma once
/**
 * @file app.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Core application model
 *
 */

#include <boost/asio.hpp>

#include <string_view>

struct lua_State;

/// An io_context whose pending handlers can be destroyed before the context
/// itself, so ~App can do that while Lua is still open.
struct IoContext : boost::asio::io_context
{
    using boost::asio::io_context::io_context;

    /// Destroy every handler not yet invoked, leaving the services in place
    /// so I/O objects can still be destroyed afterwards. The destructor
    /// repeats this harmlessly.
    using boost::asio::execution_context::shutdown;
};

class App
{
    IoContext io_context;
    boost::asio::posix::stream_descriptor stdin_poll;
    boost::asio::signal_set signals;
    lua_State* L;
    char const* main_source;

    // Lifecycle state. Lua may change it from inside a callback, while the
    // coroutine that called it is still running, so the coroutines check it
    // after every wake-up and every callback rather than relying on cancel().
    bool shutting_down = false; // set by shutdown(); never cleared
    bool ui = false; // start_ui() has set up the terminal; never cleared
    bool started = false; // startup() is running the event loop
    bool input_running = false; // input enabled: from start_ui(), or since
                                // start_input()
    unsigned input_generation = 0; // a stdin_thread exits once it changes
    bool resize_pending = false; // SIGWINCH arrived while input was stopped
    bool catch_signals = false; // SIGINT, SIGTERM and SIGHUP go to on_signal

public:
    App(char const* filename);
    ~App();

    static auto from_lua(lua_State*) -> App*;
    auto startup() -> void;
    auto shutdown() -> void;
    /// Load and run the main file. Returns whether it loaded; an error while
    /// running it is reported through safecall and counted by
    /// safecall_failures(), which makes the exit status a failure.
    auto reload() -> bool;

    auto get_context() -> boost::asio::io_context&
    {
        return io_context;
    }

    auto get_lua() const -> lua_State*
    {
        return L;
    }

    auto has_ui() const -> bool
    {
        return ui;
    }

    /// Set up the terminal for a full-screen UI and start reading keys and
    /// handling signals. Until then a program has no terminal state, reads
    /// no input, and leaves every signal its default action. One-way: does
    /// nothing if the UI is already up, or after shutdown().
    auto start_ui() -> void;

    /// Start reading the terminal. Does nothing if input is already running,
    /// or after shutdown(). A resize that arrived while input was stopped is
    /// handled once the caller returns to the event loop.
    auto start_input() -> void;

    /// Stop reading the terminal and leave curses mode, for example to hand
    /// the tty to a child process. Takes effect at once, even from inside an
    /// input callback: no further key is read or delivered. Does nothing
    /// after shutdown().
    auto stop_input() -> void;

    /// Deliver SIGINT, SIGTERM and SIGHUP to Lua's on_signal rather than
    /// restoring the terminal and taking the default action. Until
    /// shutdown(), which hands every signal but SIGUSR1 and SIGWINCH back
    /// to its default action.
    auto set_catch_signals(bool const on) -> void
    {
        catch_signals = on;
    }

    /**
     * @brief Restore the terminal, report a fatal error, and exit.
     *
     * Destructors are deliberately skipped: unwinding App with work still
     * pending in the io_context is not safe.
     *
     * It may be called at any point, including from App's constructor before
     * the Lua state exists or the UI has started, and from main's handler
     * for an exception that may be std::bad_alloc. So it must use only
     * process-wide state (no App instance, no Lua state), touch the terminal
     * only once start_ui has taken it (restore_terminal checks), and not
     * allocate.
     */
    [[noreturn]] static auto fatal(std::string_view message) -> void;

private:
    auto signal_thread() -> boost::asio::awaitable<void>;
    auto stdin_thread(unsigned generation) -> boost::asio::awaitable<void>;
    auto resize() -> void;
    auto suspend() -> void;
    auto terminate_signal(int sig) -> void;
    auto spawn_reader() -> void;
    auto spawn_ui() -> void;
};
