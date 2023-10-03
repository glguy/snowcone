#pragma once

#include <boost/asio.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <deque>
#include <functional>
#include <memory>

struct lua_State;

class irc_connection : public std::enable_shared_from_this<irc_connection>
{
public:
    using tcp_socket = boost::asio::ip::tcp::socket;

private:
    boost::asio::steady_timer write_timer;
    lua_State *L;
    std::deque<int> write_refs;
    std::deque<boost::asio::const_buffer> write_buffers;

public:
    irc_connection(boost::asio::io_context& io_context, lua_State *L);
    virtual ~irc_connection();

    auto operator=(irc_connection const&) -> irc_connection& = delete;
    auto operator=(irc_connection &&) -> irc_connection& = delete;
    irc_connection(irc_connection const&) = delete;
    irc_connection(irc_connection &&) = delete;

    auto write_thread(std::size_t = 0) -> void;
    auto virtual async_write() -> void = 0;

    auto write(char const * const cmd, size_t const n, int const ref) -> void;

    auto virtual close() -> boost::system::error_code = 0;
    auto virtual read_awaitable(boost::asio::mutable_buffer const& buffers) -> boost::asio::awaitable<std::size_t> = 0;
    auto virtual connect(
        boost::asio::ip::tcp::resolver::results_type const&,
        std::string const&,
        std::string_view,
        uint16_t
    ) -> boost::asio::awaitable<std::string> = 0;

    static auto basic_connect(
        tcp_socket& socket,
        boost::asio::ip::tcp::resolver::results_type const& endpoints,
        std::string_view socks_host,
        uint16_t socks_port
    ) -> boost::asio::awaitable<void>;

    // implementation used by plain_connection and tls_connection
    // templated so that it works over different socket implementations
    template <typename AsyncWriteStream>
    auto async_write_impl(AsyncWriteStream& socket) -> void
    {
        boost::asio::async_write(
            socket,
            write_buffers,
            [self = shared_from_this(), n = write_buffers.size()]
            (auto const error, auto)
            {
                if (not error)
                {
                    self->write_thread(n);
                }
            });
    }

    static std::size_t const irc_buffer_size = 131'072;
};

