#pragma once

#include <boost/asio.hpp>

#include <deque>
#include <functional>
#include <memory>

struct lua_State;

class irc_connection : public std::enable_shared_from_this<irc_connection>
{
private:
    boost::asio::steady_timer write_timer;
    lua_State *L;
    std::deque<int> write_refs;

protected:
    std::deque<boost::asio::const_buffer> write_buffers;

public:
    irc_connection(boost::asio::io_context& io_context, lua_State *L);
    virtual ~irc_connection();

    auto operator=(irc_connection const&) -> irc_connection& = delete;
    auto operator=(irc_connection &&) -> irc_connection& = delete;
    irc_connection(irc_connection const&) = delete;
    irc_connection(irc_connection &&) = delete;

    static auto write_thread(std::shared_ptr<irc_connection>) -> void;

    auto write(char const * const cmd, size_t const n, int const ref) -> void;

    auto virtual close() -> boost::system::error_code = 0;
    auto virtual async_write(std::function<void()> &&) -> void = 0;
    auto virtual read_awaitable(boost::asio::mutable_buffers_1 const& buffers) -> boost::asio::awaitable<std::size_t> = 0;
    auto virtual connect(
        boost::asio::ip::tcp::resolver::results_type const&,
        std::string const&,
        std::string_view,
        uint16_t
    ) -> boost::asio::awaitable<std::string> = 0;

    static auto basic_connect(
        boost::asio::ip::tcp::socket& socket,
        boost::asio::ip::tcp::resolver::results_type const& endpoints,
        std::string_view socks_host,
        uint16_t socks_port
    ) -> boost::asio::awaitable<void>;
};
