#pragma once

#include "stream.hpp"

namespace
{
auto close_stream(boost::asio::ip::tcp::socket &stream) -> void;

template <typename T>
auto close_stream(boost::asio::ssl::stream<T> &stream) -> void
{
    close_stream(stream.next_layer());
}
} // namespace

template <typename T>
auto TlsStream<T>::async_read_some_(mutable_buffers buffers, handler_type handler) -> void
{
    stream_.async_read_some(buffers, std::move(handler));
}

template <typename T>
auto TlsStream<T>::async_write_some_(const_buffers buffers, handler_type handler) -> void
{
    stream_.async_write_some(buffers, std::move(handler));
}

template <typename T>
auto TlsStream<T>::close() -> void
{
    close_stream(stream_);
}

template <typename T>
auto TlsStream<T>::set_buffer_size(std::size_t const size) -> void
{
    auto const ssl = stream_.native_handle();
    BIO_set_buffer_size(SSL_get_rbio(ssl), size);
    BIO_set_buffer_size(SSL_get_wbio(ssl), size);
}
