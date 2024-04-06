#pragma once

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <cstdint>
#include <variant>

template <typename... Ts>
struct Stream
{
    std::variant<Ts...> impl_;

    // AsyncReadStream and AsyncWriteStream type requirement
    using executor_type = boost::asio::any_io_executor;
    auto get_executor() noexcept -> executor_type
    {
        return std::visit([](auto& x) -> executor_type { return x.get_executor(); }, impl_);
    }

    // AsyncReadStream type requirement
    template <
        typename MutableBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token>
    auto async_read_some(
        MutableBufferSequence &&buffers,
        Token &&token)
    {
        return std::visit([&](auto& x) {
            return x.async_read_some(std::forward<MutableBufferSequence>(buffers), std::forward<Token>(token));
        }, impl_);
    }

    // AsyncWriteStream type requirement
    template <
        typename ConstBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token>
    auto async_write_some(
        ConstBufferSequence &&buffers,
        Token &&token)
    {
        return std::visit([&](auto& x) {
            return x.async_write_some(std::forward<ConstBufferSequence>(buffers), std::forward<Token>(token));
        }, impl_);
    }

    // Gracefully tear down the network stream
    auto close() -> void;

    // Update send and receive buffer sizes
    auto set_buffer_size(std::size_t const size) -> void;

    auto get_impl() -> std::variant<Ts...>&
    {
        return impl_;
    }
};

using CommonStream = Stream<boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
extern template class Stream<boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
