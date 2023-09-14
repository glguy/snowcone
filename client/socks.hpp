#pragma once

#include <boost/asio.hpp>

auto socks_connect(
    boost::asio::ip::tcp::socket& socket,
    std::string_view host,
    uint16_t port
) -> boost::asio::awaitable<void>;
