#include "stream-impl.hpp"

auto stream_close(boost::asio::ip::tcp::socket &stream) -> void
{
    boost::system::error_code err;
    stream.shutdown(stream.shutdown_both, err);
    stream.close(err);
}


auto stream_set_buffer_size(boost::asio::ip::tcp::socket& stream, std::size_t const size) -> void
{
    stream.set_option(boost::asio::ip::tcp::socket::send_buffer_size{static_cast<int>(size)});
    stream.set_option(boost::asio::ip::tcp::socket::receive_buffer_size{static_cast<int>(size)});
}

template class Stream<boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
