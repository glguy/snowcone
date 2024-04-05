#pragma once

#include "connect.hpp"

#include <boost/io/ios_state.hpp>
#include <iomanip>

template <Connectable T>
auto SocksConnectParams<T>::connect(std::ostream& os, stream_type &stream) -> boost::asio::awaitable<void>
{
    co_await base.connect(os, stream);
    os << " socks=";
    os << co_await socks5::async_connect(stream, host, port, auth, boost::asio::use_awaitable);
}

namespace {
auto peer_fingerprint(std::ostream &os, SSL const *const ssl) -> void;
}

template <Connectable T>
auto TlsConnectParams<T>::connect(std::ostream& os, stream_type &stream) -> boost::asio::awaitable<void>
{
    co_await base.connect(os, stream.next_layer());
    os << " tls=";

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
