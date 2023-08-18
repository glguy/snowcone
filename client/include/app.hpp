#pragma once

#include <string>

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

struct lua_State;

struct App
{
    boost::asio::io_context io_context;
    boost::asio::posix::stream_descriptor stdin_poll;
    boost::asio::signal_set winch;

    lua_State *L;
    std::string paste;
    bool in_paste = false;
    mbstate_t mbstate{};

    App();
    ~App();

    static auto from_lua(lua_State *) -> App *;

    auto do_mouse(int y, int x) -> void;
    auto do_keyboard(long key) -> void;
    auto do_paste() -> void;

    auto startup() -> void;
    auto shutdown() -> void;

    auto start_stdin() -> void;
    auto start_winch() -> void;
};
