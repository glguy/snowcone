#include "stream.hpp"

#include "websocket.hpp"

namespace {

/// @brief Tear down a socket
template <typename Protocol, typename Executor>
auto close_it(boost::asio::basic_socket<Protocol, Executor> & socket) -> void
{
    boost::system::error_code err;
    socket.shutdown(socket.shutdown_both, err);
    socket.close(err);
}

/// @brief Close a TLS stream abruptly by closing the stream it wraps, with no
/// close_notify
auto close_it(boost::asio::ssl::stream<Stream> & socket) -> void
{
    socket.next_layer().close();
}

/// @brief Close a WebSocket abruptly, with no close frame
auto close_it(websocket::LineStream & socket) -> void
{
    socket.close();
}

/// StreamBase over a concrete stream T, forwarding each operation to it
template <typename T>
struct StreamImpl final : public StreamBase
{
    T impl;

    /// Construct impl from args
    template <typename... Args>
    explicit StreamImpl(Args&&... args) : impl{std::forward<Args>(args)...}
    {
    }

    /// Forward to impl.async_read_some
    auto async_read_some(
        std::vector<boost::asio::mutable_buffer> buffers,
        boost::asio::any_completion_handler<StreamBase::Sig> handler
    ) -> void override
    {
        impl.async_read_some(buffers, std::move(handler));
    }

    /// Forward to impl.async_write_some
    auto async_write_some(
        std::vector<boost::asio::const_buffer> buffers,
        boost::asio::any_completion_handler<StreamBase::Sig> handler
    ) -> void override
    {
        impl.async_write_some(buffers, std::move(handler));
    }

    /// Abrupt close, by close_it for T
    auto close() -> void override {
        close_it(impl);
    }

    /// impl's close_reason() when T has one, else empty
    auto close_reason() const -> std::string override
    {
        if constexpr (requires { impl.close_reason(); })
        {
            return impl.close_reason();
        }
        else
        {
            return {};
        }
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

auto Stream::upgrade_websocket() -> websocket::LineStream&
{
    auto impl = std::make_shared<StreamImpl<websocket::LineStream>>(*this);
    auto& result = impl->impl;
    self = std::move(impl);
    return result;
}
