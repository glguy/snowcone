#pragma once

#include <boost/asio.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <deque>
#include <functional>
#include <memory>
#include <optional>

#include "../net/stream.hpp"

struct lua_State;

struct Settings
{
    bool tls;
    std::string host;
    std::uint16_t port;

    std::string client_cert;
    std::string client_key;
    std::string client_key_password;
    std::string verify;
    std::string sni;

    std::string socks_host;
    std::uint16_t socks_port;
    std::string socks_user;
    std::string socks_pass;

    std::string bind_host;
    std::uint16_t bind_port;
};

class irc_connection final : public std::enable_shared_from_this<irc_connection>
{
public:
    using stream_type = CommonStream;
    static std::size_t const irc_buffer_size = 131'072;

private:
    boost::asio::steady_timer write_timer;
    lua_State *L;
    std::deque<int> write_refs;
    std::deque<boost::asio::const_buffer> write_buffers;
    stream_type stream_;

public:
    auto get_stream() -> stream_type&
    {
        return stream_;
    }
    
    auto get_lua() const -> lua_State*
    {
        return L;
    }

    irc_connection(boost::asio::io_context&, lua_State *L, stream_type&&);
    ~irc_connection();

    auto operator=(irc_connection const&) -> irc_connection& = delete;
    auto operator=(irc_connection &&) -> irc_connection& = delete;
    irc_connection(irc_connection const&) = delete;
    irc_connection(irc_connection &&) = delete;

    // Queue messages for writing
    auto write(std::string_view cmd, int const ref) -> void;

    auto close() -> void { stream_.close(); }

    // Either write data now or wait for there to be data
    auto write_thread() -> void;

    auto connect(Settings settings) -> boost::asio::awaitable<std::string>;

private:
    // There's data now, actually write it
    auto write_thread_actual() -> void;
};
