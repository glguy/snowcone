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
    bool headless; // script mode: no terminal, no keyboard input, no signals

    // Lifecycle state. Lua may change it from inside a callback, while the
    // coroutine that called it is still running, so the coroutines check it
    // after every wake-up and every callback rather than relying on cancel().
    bool shutting_down = false; // set by shutdown(); never cleared
    bool started = false; // startup() has spawned the coroutines
    bool input_running = false; // input enabled: from construction (unless
                                // headless), or since start_input()
    unsigned input_generation = 0; // a stdin_thread exits once it changes
    bool resize_pending = false; // SIGWINCH arrived while input was stopped

public:
    App(char const* filename, bool headless);
    ~App();

    static auto from_lua(lua_State*) -> App*;
    auto startup() -> void;
    auto shutdown() -> void;
    auto reload() -> bool;

    auto get_context() -> boost::asio::io_context&
    {
        return io_context;
    }

    auto get_lua() const -> lua_State*
    {
        return L;
    }

    auto is_headless() const -> bool
    {
        return headless;
    }

    /// Start reading the terminal. Does nothing if input is already running,
    /// or after shutdown(). A resize that arrived while input was stopped is
    /// handled once the caller returns to the event loop.
    auto start_input() -> void;

    /// Stop reading the terminal and leave curses mode, for example to hand
    /// the tty to a child process. Takes effect at once, even from inside an
    /// input callback: no further key is read or delivered. Does nothing
    /// after shutdown().
    auto stop_input() -> void;

    /**
     * @brief Restore the terminal, report a fatal error, and exit.
     *
     * Destructors are deliberately skipped: unwinding App with work still
     * pending in the io_context is not safe.
     */
    [[noreturn]] static auto fatal(std::string_view message) -> void;

private:
    auto signal_thread() -> boost::asio::awaitable<void>;
    auto stdin_thread(unsigned generation) -> boost::asio::awaitable<void>;
    auto resize() -> void;
    auto spawn_reader() -> void;
};
