#include "plain_connection.hpp"

plain_irc_connection::plain_irc_connection(boost::asio::io_context &io_context, lua_State *const L)
    : irc_connection{io_context, L}, socket_{io_context}
{
}

auto plain_irc_connection::write_thread() -> void
{
    write_thread_impl(socket_);
}

auto plain_irc_connection::read_awaitable(
    boost::asio::mutable_buffer const& buffers
) -> boost::asio::awaitable<std::size_t>
{
    return socket_.async_read_some(buffers, boost::asio::use_awaitable);
}

auto plain_irc_connection::connect(
    boost::asio::ip::tcp::resolver::results_type const& endpoints,
    std::string const&,
    std::string_view socks_host,
    uint16_t socks_port
) -> boost::asio::awaitable<std::string>
{
    co_await irc_connection::basic_connect(socket_, endpoints, socks_host, socks_port);
    co_return ""; // no fingerprint
}

auto plain_irc_connection::close() -> boost::system::error_code
{
    boost::system::error_code error;
    return socket_.close(error);
}
