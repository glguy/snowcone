#include "stream-impl.hpp"

namespace {
auto close_stream(boost::asio::ip::tcp::socket &stream) -> void
{
    boost::system::error_code err;
    stream.shutdown(stream.shutdown_both, err);
    stream.close(err);
}
} // namespace

auto TcpStream::async_read_some_(mutable_buffers buffers, handler_type handler) -> void
{
    stream_.async_read_some(buffers, std::move(handler));
}

auto TcpStream::async_write_some_(const_buffers buffers, handler_type handler) -> void
{
    stream_.async_write_some(buffers, std::move(handler));
}

auto TcpStream::close() -> void
{
    close_stream(stream_);
}

template class TlsStream<boost::asio::ip::tcp::socket>;
