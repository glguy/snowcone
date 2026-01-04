#include "stream.hpp"

#include <span>

namespace {

/// @brief Tear down the network stream
auto close_it(boost::asio::ip::tcp::socket::lowest_layer_type & socket) -> void
{
    boost::system::error_code err;
    socket.shutdown(socket.shutdown_both, err);
    socket.close(err);
}

auto close_it(boost::asio::local::stream_protocol::socket::lowest_layer_type & socket) -> void
{
    boost::system::error_code err;
    socket.shutdown(socket.shutdown_both, err);
    socket.close(err);
}

auto close_it(boost::asio::ssl::stream<Stream> & socket) -> void
{
    socket.next_layer().close();
}

template <typename T>
struct StreamImpl final : public StreamBase
{
    T impl;

    template <typename... Args>
    explicit StreamImpl(Args&&... args) : impl{std::forward<Args>(args)...}
    {
    }

    ~StreamImpl() = default;

    auto async_read_some(
        std::vector<boost::asio::mutable_buffer> buffers,
        boost::asio::any_completion_handler<StreamBase::Sig> handler
    ) -> void override
    {
        impl.async_read_some(buffers, std::move(handler));
    }

    auto async_write_some(
        std::vector<boost::asio::const_buffer> buffers,
        boost::asio::any_completion_handler<StreamBase::Sig> handler
    ) -> void override
    {
        impl.async_write_some(buffers, std::move(handler));
    }

    auto close() -> void override {
        close_it(impl);
    }
};

}

auto Stream::reset_ip() -> boost::asio::ip::tcp::socket&
{
    auto impl = std::make_shared<StreamImpl<boost::asio::ip::tcp::socket>>(*io_context);
    auto& result = impl->impl;
    self = std::move(impl);
    return result;
}

auto Stream::reset_local() -> boost::asio::local::stream_protocol::socket&
{
    auto impl = std::make_shared<StreamImpl<boost::asio::local::stream_protocol::socket>>(*io_context);
    auto& result = impl->impl;
    self = std::move(impl);
    return result;
}

auto Stream::upgrade(boost::asio::ssl::context& ctx) -> boost::asio::ssl::stream<Stream>&
{
    auto impl = std::make_shared<StreamImpl<boost::asio::ssl::stream<Stream>>>(*this, ctx);
    auto& result = impl->impl;
    self = std::move(impl);
    return result;
}
