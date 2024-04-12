#pragma once

#include "connect.hpp"

#include <boost/io/ios_state.hpp>
#include <iomanip>

namespace {
auto peer_fingerprint(std::ostream &os, SSL const *const ssl) -> void;
}

template <typename T>
auto tls_connect(
    std::ostream& os,
    boost::asio::ssl::stream<T>& stream,
    std::string const& verify,
    std::string const& sni
) -> boost::asio::awaitable<void>
{
    os << "tls=";

    // TLS connection
    if (not verify.empty())
    {
        stream.set_verify_mode(boost::asio::ssl::verify_peer);
        stream.set_verify_callback(boost::asio::ssl::host_name_verification(verify));
    }

    if (not sni.empty())
    {
        SSL_set_tlsext_host_name(stream.native_handle(), sni.c_str());
    }
    co_await stream.async_handshake(stream.client, boost::asio::use_awaitable);
    peer_fingerprint(os, stream.native_handle());
}
