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

    auto virtual write_thread() -> void = 0;

    auto write(char const * const cmd, size_t const n, int const ref) -> void;

    auto virtual close() -> boost::system::error_code = 0;
    auto virtual read_awaitable(boost::asio::mutable_buffer const& buffers) -> boost::asio::awaitable<std::size_t> = 0;
    auto virtual connect(
        boost::asio::ip::tcp::resolver::results_type const&,
        std::string const&,
        std::string_view,
        uint16_t,
        std::string_view socks_user,
        std::string_view socks_pass
    ) -> boost::asio::awaitable<std::string> = 0;

    static auto basic_connect(
        tcp_socket& socket,
        boost::asio::ip::tcp::resolver::results_type const& endpoints,
        std::string_view socks_host,
        uint16_t socks_port,
        std::string_view socks_user,
        std::string_view socks_pass
    ) -> boost::asio::awaitable<void>;

    static std::size_t const irc_buffer_size = 131'072;

    template <typename AsyncWriteStream>
    auto write_thread_impl_go(AsyncWriteStream & stream) -> void
    {
        boost::asio::async_write(
            stream,
            write_buffers,
            [weak = weak_from_this(), n = write_buffers.size(), &stream]
            (boost::system::error_code const& error, std::size_t)
            {
                if (not error)
                {
                    if (auto self = weak.lock())
                    {
                        for (std::size_t i = 0; i < n; i++)
                        {
                            luaL_unref(self->L, LUA_REGISTRYINDEX, self->write_refs.front());
                            self->write_buffers.pop_front();
                            self->write_refs.pop_front();
                        }

                        self->write_thread_impl(stream);
                    }
                }
            });
    }

    template <typename AsyncWriteStream>
    auto write_thread_impl(AsyncWriteStream & stream) -> void
    {
        if (write_buffers.empty())
        {
            write_timer.async_wait(
                [weak = weak_from_this(), &stream](auto)
                {
                    if (auto self = weak.lock())
                    {
                        if (not self->write_buffers.empty())
                        {
                            self->write_thread_impl_go(stream);
                        }
                    }
                }
            );
        }
        else
        {
            write_thread_impl_go(stream);
        }
    }
};

