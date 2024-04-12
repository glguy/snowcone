#pragma once

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <cstddef>
#include <variant>

/// @brief Abstraction over a choice of Boost ASIO stream types.
///
/// AsyncReadStream and AsyncWriteStream operations will dispatch
/// to the underlying stream representation representation.
///
/// @tparam ...Ts These types should satisfy AsyncReadStream and AsyncWriteStream
template <typename... Ts>
struct Stream
{
    std::variant<Ts...> impl_;

    // AsyncReadStream and AsyncWriteStream type requirement
    using executor_type = boost::asio::any_io_executor;

    /// @brief Get executor associated with this stream
    auto get_executor() -> executor_type
    {
        return std::visit([](auto&& x) -> executor_type {
            return x.get_executor();
        }, impl_);
    }

    /// @brief AsyncReadStream method
    /// @param buffers Buffers to read into
    /// @param token Completion token for read operation
    /// @return Return determined by completion token
    template <
        typename MutableBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token>
    auto async_read_some(
        MutableBufferSequence &&buffers,
        Token &&token)
    {
        return std::visit([&](auto&& x) {
            return x.async_read_some(std::forward<MutableBufferSequence>(buffers), std::forward<Token>(token));
        }, impl_);
    }

    /// @brief AsyncWriteStream method
    /// @param buffers Buffers to write from
    /// @param token Completion token for write operation
    /// @return Return determined by completion token
    template <
        typename ConstBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token>
    auto async_write_some(
        ConstBufferSequence &&buffers,
        Token &&token)
    {
        return std::visit([&](auto&& x) {
            return x.async_write_some(std::forward<ConstBufferSequence>(buffers), std::forward<Token>(token));
        }, impl_);
    }

    /// @brief Gracefully tear down the network stream
    auto close() -> void;

    /// @brief Access underlying stream
    auto get_impl() noexcept -> std::variant<Ts...>&
    {
        return impl_;
    }
};

using CommonStream = Stream<boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
extern template class Stream<boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
