#pragma once

#include "irc_connection.hpp"

#include <boost/asio.hpp>

class plain_irc_connection final : public irc_connection
{
    tcp_socket socket_;

public:
    plain_irc_connection(boost::asio::io_context &io_context, lua_State *const L);

    auto async_write() -> void override;

    auto read_awaitable(
        boost::asio::mutable_buffer const& buffers
    ) -> boost::asio::awaitable<std::size_t> override;

    auto connect(
        boost::asio::ip::tcp::resolver::results_type const& endpoints,
        std::string const&,
        std::string_view socks_host,
        uint16_t socks_port
    ) -> boost::asio::awaitable<std::string> override;

    auto close() -> boost::system::error_code override;
};
