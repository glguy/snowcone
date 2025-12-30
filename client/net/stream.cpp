#include "stream.hpp"

#include <span>

namespace {

template <typename T>
struct StreamImpl final : public StreamBase
{
    T impl;

    template <typename... Args>
    explicit StreamImpl(Args&&... args) : impl{std::forward<Args>(args)...}
    {
    }

    ~StreamImpl() = default;

    auto lowest_layer() -> lowest_layer_type& override
    {
        return impl.lowest_layer();
    }

    auto lowest_layer() const -> lowest_layer_type const& override
    {
        return impl.lowest_layer();
    }

    auto get_executor() -> executor_type override
    {
        return impl.get_executor();
    }

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
};

}

auto Stream::reset(executor_type ex) -> boost::asio::ip::tcp::socket&
{
    auto impl = std::make_shared<StreamImpl<boost::asio::ip::tcp::socket>>(ex);
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

/// @brief Tear down the network stream
auto Stream::close() -> void
{
    boost::system::error_code err;
    auto& socket = lowest_layer();
    socket.shutdown(socket.shutdown_both, err);
    socket.lowest_layer().close(err);
}
