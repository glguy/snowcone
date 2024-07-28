#pragma once

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <cstddef>
#include <variant>

/// @brief Abstraction over plain-text and TLS streams.
class Stream : private
    std::variant<
        boost::asio::ip::tcp::socket,
        boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>
{
public:
    using tcp_socket = boost::asio::ip::tcp::socket;
    using tls_stream = boost::asio::ssl::stream<tcp_socket>;

    /// @brief The type of the executor associated with the stream.
    using executor_type = boost::asio::any_io_executor;

    /// @brief Type of the lowest layer of this stream
    using lowest_layer_type = tcp_socket::lowest_layer_type;

private:
    using base_type = std::variant<tcp_socket, tls_stream>;
    auto base() -> base_type& { return *this; }
    auto base() const -> base_type const& { return *this; }

public:

    /// @brief Initialize stream with a plain TCP socket
    /// @param ioc IO context of stream
    template <typename T>
    Stream(T&& executor) : base_type{std::in_place_type<tcp_socket>, std::forward<T>(executor)} {}

    /// @brief Reset stream to a plain TCP socket
    /// @return Reference to internal socket object
    auto reset() -> tcp_socket&
    {
        return base().template emplace<tcp_socket>(get_executor());
    }

    /// @brief Upgrade a plain TCP socket into a TLS stream.
    /// @param ctx TLS context used for handshake
    /// @return Reference to internal stream object
    auto upgrade(boost::asio::ssl::context& ctx) -> tls_stream&
    {
        auto socket = std::move(std::get<tcp_socket>(base()));
        return base().template emplace<tls_stream>(std::move(socket), ctx);
    }

    /// @brief Get underlying basic socket
    /// @return Reference to underlying socket
    auto lowest_layer() -> lowest_layer_type&
    {
        return std::visit([](auto&& x) -> decltype(auto) { return x.lowest_layer(); }, base());
    }

    /// @brief Get underlying basic socket
    /// @return Reference to underlying socket
    auto lowest_layer() const -> lowest_layer_type const&
    {
        return std::visit([](auto&& x) -> decltype(auto) { return x.lowest_layer(); }, base());
    }

    /// @brief Get the executor associated with this stream.
    /// @return The executor associated with the stream.
    auto get_executor() -> executor_type const&
    {
        return lowest_layer().get_executor();
    }

    /// @brief Initiates an asynchronous read operation.
    /// @tparam MutableBufferSequence Type of the buffer sequence.
    /// @tparam Token Type of the completion token.
    /// @param buffers The buffer sequence into which data will be read.
    /// @param token The completion token for the read operation.
    /// @return The result determined by the completion token.
    template <
        typename MutableBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token>
    auto async_read_some(MutableBufferSequence&& buffers, Token&& token) -> decltype(auto)
    {
        return std::visit([&buffers, &token](auto&& x) -> decltype(auto) {
            return x.async_read_some(std::forward<MutableBufferSequence>(buffers), std::forward<Token>(token));
        }, base());
    }

    /// @brief Initiates an asynchronous write operation.
    /// @tparam ConstBufferSequence Type of the buffer sequence.
    /// @tparam Token Type of the completion token.
    /// @param buffers The buffer sequence from which data will be written.
    /// @param token The completion token for the write operation.
    /// @return The result determined by the completion token.
    template <
        typename ConstBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token>
    auto async_write_some(ConstBufferSequence&& buffers, Token&& token) -> decltype(auto)
    {
        return std::visit([&buffers, &token](auto&& x) -> decltype(auto) {
            return x.async_write_some(std::forward<ConstBufferSequence>(buffers), std::forward<Token>(token));
        }, base());
    }

    /// @brief Tear down the network stream
    auto close() -> void
    {
        boost::system::error_code err;
        auto& socket = lowest_layer();
        socket.shutdown(socket.shutdown_both, err);
        socket.lowest_layer().close(err);
    }
};
