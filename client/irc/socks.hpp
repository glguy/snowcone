#pragma once

#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/awaitable.hpp>

#include <cstdint>
#include <string_view>

auto socks_connect(
    boost::asio::ip::tcp::socket& socket,
    std::string_view host,
    uint16_t port
) -> boost::asio::awaitable<void>;
