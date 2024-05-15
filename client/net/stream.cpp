#include "stream-impl.hpp"

auto stream_close(boost::asio::ip::tcp::socket& stream) -> void
{
    boost::system::error_code err;
    stream.shutdown(stream.shutdown_both, err);
    stream.close(err);
}

template class Stream<boost::asio::any_io_executor, boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
