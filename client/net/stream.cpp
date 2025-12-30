#include "stream.hpp"

namespace {


struct StreamSocket final : public StreamBase
{
    boost::asio::ip::tcp::socket socket;

    template <typename... Args>
    explicit StreamSocket(Args&&... args)
        : socket{std::forward<Args>(args)...}
    {
    }

    ~StreamSocket() = default;

    auto lowest_layer() -> lowest_layer_type& override
    {
        return socket.lowest_layer();
    }

    auto lowest_layer() const -> lowest_layer_type const& override
    {
        return socket.lowest_layer();
    }

    auto get_executor() -> executor_type override
    {
        return socket.get_executor();
    }

    auto async_read_some(std::vector<boost::asio::mutable_buffer> buffers, boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler) -> void override
    {
        socket.async_read_some(buffers, std::move(handler));
    }

    auto async_write_some(std::vector<boost::asio::const_buffer> buffers, boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler) -> void override
    {
        socket.async_write_some(buffers, std::move(handler));
    }
};

struct StreamTLS : public StreamBase
{
    boost::asio::ssl::stream<Stream> stream;

    template <typename... Args>
    explicit StreamTLS(Args&&... args)
        : stream{std::forward<Args>(args)...}
    {
    }

    ~StreamTLS() = default;

    auto lowest_layer() -> lowest_layer_type& override
    {
        return stream.lowest_layer();
    }

    auto lowest_layer() const -> lowest_layer_type const& override
    {
        return stream.lowest_layer();
    }

    auto get_executor() -> executor_type override
    {
        return stream.get_executor();
    }

    auto async_read_some(
        std::vector<boost::asio::mutable_buffer> buffers,
        boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler
    ) -> void override
    {
        stream.async_read_some(buffers, std::move(handler));
    }

    auto async_write_some(
        std::vector<boost::asio::const_buffer> buffers,
        boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler
    ) -> void override
    {
        stream.async_write_some(buffers, std::move(handler));
    }
};

}

auto Stream::reset(executor_type ex) -> boost::asio::ip::tcp::socket&
{
    auto impl = std::make_shared<StreamSocket>(ex);
    auto& result = impl->socket;
    self = std::move(impl);
    return result;
}

auto Stream::upgrade(boost::asio::ssl::context& ctx) -> boost::asio::ssl::stream<Stream>&
{
    auto impl = std::make_shared<StreamTLS>(*this, ctx);
    auto& result = impl->stream;
    self = std::move(impl);
    return result;
}

/// @brief Tear down the network stream
auto Stream::close() -> void
{
    boost::system::error_code err;
    auto& socket = lowest_layer();
    socket.shutdown(socket.shutdown_both, err);
    socket.lowest_layer().close(err);
}
