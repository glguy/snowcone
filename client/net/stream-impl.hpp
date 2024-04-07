#pragma once

#include "stream.hpp"

auto stream_close(boost::asio::ip::tcp::socket& stream) -> void;

template <typename T>
auto stream_close(boost::asio::ssl::stream<T>& stream) -> void
{
    stream_close(stream.next_layer());
}

template <typename... Ts>
auto Stream<Ts...>::close() -> void
{
    std::visit([](auto&& x){ stream_close(x); }, impl_);
}

auto stream_set_buffer_size(boost::asio::ip::tcp::socket&, std::size_t const) -> void;

template <typename T>
auto stream_set_buffer_size(boost::asio::ssl::stream<T>& stream, std::size_t const n) -> void
{
    stream_set_buffer_size(stream.next_layer(), n);
    auto const ssl = stream.native_handle();
    BIO_set_buffer_size(SSL_get_rbio(ssl), n);
    BIO_set_buffer_size(SSL_get_wbio(ssl), n);
}

template <typename... Ts>
auto Stream<Ts...>::set_buffer_size(std::size_t const n) -> void
{
    std::visit([n](auto&& x) { stream_set_buffer_size(x, n);}, impl_);
}