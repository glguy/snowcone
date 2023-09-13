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

struct App
{
    boost::asio::io_context io_context;
    boost::asio::posix::stream_descriptor stdin_poll;
    boost::asio::signal_set winch;

    lua_State * L;

    App();
    ~App();

    static auto from_lua(lua_State *) -> App *;

    auto do_mouse(int y, int x) -> void;
    auto do_keyboard(long key) -> void;
    auto do_paste(std::string_view) -> void;

    auto startup() -> void;
    auto shutdown() -> void;

private:
    auto winch_thread() -> boost::asio::awaitable<void>;
    auto stdin_thread() -> boost::asio::awaitable<void>;
};
