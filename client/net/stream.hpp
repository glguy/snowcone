#pragma once

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <cstddef>
#include <variant>

class StreamBase
{
public:
    using executor_type = boost::asio::any_io_executor;
    using lowest_layer_type = boost::asio::ip::tcp::socket::lowest_layer_type;

    virtual ~StreamBase() = default;
    virtual auto lowest_layer() -> lowest_layer_type& = 0;
    virtual auto lowest_layer() const -> lowest_layer_type const& = 0;
    virtual auto get_executor() -> executor_type = 0;
    virtual auto async_read_some(std::vector<boost::asio::mutable_buffer> buffers, boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler) -> void = 0;
    virtual auto async_write_some(std::vector<boost::asio::const_buffer> buffers, boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler) -> void = 0;
};

class Stream
{
    std::shared_ptr<StreamBase> self;

public:
    /// @brief The type of the executor associated with the stream.
    using executor_type = StreamBase::executor_type;

    /// @brief Type of the lowest layer of this stream
    using lowest_layer_type = StreamBase::lowest_layer_type;

    /// @brief Reset stream to a plain TCP socket
    /// @return Reference to internal socket object
    auto reset(executor_type) -> boost::asio::ip::tcp::socket&;

    /// @brief Upgrade a plain TCP socket into a TLS stream.
    /// @param ctx TLS context used for handshake
    /// @return Reference to internal stream object
    auto upgrade(boost::asio::ssl::context& ctx) -> boost::asio::ssl::stream<Stream>&;

    /// @brief Get underlying basic socket
    /// @return Reference to underlying socket
    auto lowest_layer() -> lowest_layer_type&
    {
        return self->lowest_layer();
    }

    /// @brief Get underlying basic socket
    /// @return Reference to underlying socket
    auto lowest_layer() const -> lowest_layer_type const&
    {
        return self->lowest_layer();
    }

    /// @brief Get the executor associated with this stream.
    /// @return The executor associated with the stream.
    auto get_executor() -> executor_type
    {
        return self->get_executor();
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
        return boost::asio::async_initiate<Token, void(boost::system::error_code, std::size_t)>(
            [](
                boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)>&& handler,
                std::shared_ptr<StreamBase> ptr,
                MutableBufferSequence && buffers
            ) {
                std::vector<boost::asio::mutable_buffer> buf{boost::asio::buffer_sequence_begin(buffers), boost::asio::buffer_sequence_end(buffers)};
                ptr->async_read_some(std::move(buf), std::move(handler));
            },
            token,
            this->self,
            std::forward<MutableBufferSequence>(buffers)
        );
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
        return boost::asio::async_initiate<Token, void(boost::system::error_code, std::size_t)>(
            [](
                boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)>&& handler,
                std::shared_ptr<StreamBase> ptr,
                ConstBufferSequence && buffers
            ) {
                std::vector<boost::asio::const_buffer> buf{boost::asio::buffer_sequence_begin(buffers), boost::asio::buffer_sequence_end(buffers)};
                ptr->async_write_some(std::move(buf), std::move(handler));
            },
            token,
            this->self,
            std::forward<ConstBufferSequence>(buffers)
        );
    }

    /// @brief Tear down the network stream
    auto close() -> void;
};
