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
    boost::asio::signal_set winch;
    lua_State * L;

public:
    App();
    ~App();

    static auto from_lua(lua_State *) -> App *;
    auto startup() -> void;
    auto shutdown() -> void;

    auto get_executor() -> boost::asio::io_context&
    {
        return io_context;
    }

    auto get_lua() const -> lua_State*
    {
        return L;
    }

private:
    auto winch_thread() -> boost::asio::awaitable<void>;
    auto stdin_thread() -> boost::asio::awaitable<void>;
};
