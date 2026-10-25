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

class App
{
    boost::asio::io_context io_context;
    boost::asio::posix::stream_descriptor stdin_poll;
    boost::asio::signal_set signals;
    lua_State* L;
    char const* main_source;
    bool headless; // script mode: no terminal, no keyboard input, no signals

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

    auto start_input() -> void;
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
    auto stdin_thread() -> boost::asio::awaitable<void>;
};
