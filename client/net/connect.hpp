#pragma once

#include <socks5.hpp>

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <iosfwd>
#include <string>
#include <tuple>

#include "stream.hpp"

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

    std::size_t buffer_size;
};

auto connect_stream(
    boost::asio::io_context& io_context,
    Settings settings
) -> boost::asio::awaitable<std::pair<CommonStream, std::string>>;
