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
    lua_State * L;
    char const* main_source;

public:
    App(char const*);
    ~App();

    static auto from_lua(lua_State *) -> App *;
    auto startup() -> void;
    auto shutdown() -> void;
    auto reload() -> bool;

    auto get_executor() -> boost::asio::io_context&
    {
        return io_context;
    }

    auto get_lua() const -> lua_State*
    {
        return L;
    }

private:
    auto signal_thread() -> boost::asio::awaitable<void>;
    auto stdin_thread() -> boost::asio::awaitable<void>;
};
