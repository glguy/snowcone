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
    using Sig = void(boost::system::error_code, std::size_t);
    virtual ~StreamBase() = default;
    virtual auto async_read_some(std::vector<boost::asio::mutable_buffer> buffers, boost::asio::any_completion_handler<Sig> handler) -> void = 0;
    virtual auto async_write_some(std::vector<boost::asio::const_buffer> buffers, boost::asio::any_completion_handler<Sig> handler) -> void = 0;
    virtual auto close() -> void = 0;
};

class Stream
{
private:
    boost::asio::io_context* io_context;
    std::shared_ptr<StreamBase> self;

public:
    /// @brief The type of the executor associated with the stream.
    using executor_type = boost::asio::any_io_executor;

    /// @brief Type of the lowest layer of this stream
    using lowest_layer_type = Stream;

    Stream(boost::asio::io_context& io_context)
        : io_context{&io_context}
        , self{}
    {
    }

    /// @brief Reset stream to a plain TCP socket
    /// @return Reference to internal socket object
    auto reset_ip() -> boost::asio::ip::tcp::socket&;

    /// @brief Reset stream to a plain TCP socket
    /// @return Reference to internal socket object
    auto reset_local() -> boost::asio::local::stream_protocol::socket&;

    /// @brief Upgrade a plain TCP socket into a TLS stream.
    /// @param ctx TLS context used for handshake
    /// @return Reference to internal stream object
    auto upgrade(boost::asio::ssl::context& ctx) -> boost::asio::ssl::stream<Stream>&;

    /// @brief Get underlying basic socket
    /// @return Reference to underlying socket
    auto lowest_layer() -> lowest_layer_type&
    {
        return *this;
    }

    /// @brief Get underlying basic socket
    /// @return Reference to underlying socket
    auto lowest_layer() const -> lowest_layer_type const&
    {
        return *this;
    }

    /// @brief Get the executor associated with this stream.
    /// @return The executor associated with the stream.
    auto get_executor() -> executor_type
    {
        return io_context->get_executor();
    }

    /// @brief Initiates an asynchronous read operation.
    /// @tparam MutableBufferSequence Type of the buffer sequence.
    /// @tparam Token Type of the completion token.
    /// @param buffers The buffer sequence into which data will be read.
    /// @param token The completion token for the read operation.
    /// @return The result determined by the completion token.
    template <
        typename MutableBufferSequence,
        boost::asio::completion_token_for<StreamBase::Sig> Token>
    auto async_read_some(MutableBufferSequence const& buffers, Token&& token) -> decltype(auto)
    {
        return boost::asio::async_initiate<Token, StreamBase::Sig>(
            [](
                boost::asio::any_completion_handler<StreamBase::Sig>&& handler,
                std::shared_ptr<StreamBase> ptr,
                std::vector<boost::asio::mutable_buffer> buffers
            ) {
                ptr->async_read_some(
                    std::move(buffers),
                    std::move(handler)
                );
            },
            token,
            this->self,
            std::vector<boost::asio::mutable_buffer>{
                boost::asio::buffer_sequence_begin(buffers),
                boost::asio::buffer_sequence_end(buffers)
            }
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
        boost::asio::completion_token_for<StreamBase::Sig> Token>
    auto async_write_some(ConstBufferSequence const& buffers, Token&& token) -> decltype(auto)
    {
        return boost::asio::async_initiate<Token, StreamBase::Sig>(
            [](
                boost::asio::any_completion_handler<StreamBase::Sig>&& handler,
                std::shared_ptr<StreamBase> ptr,
                std::vector<boost::asio::const_buffer> buffers
            ) {
                ptr->async_write_some(
                    std::move(buffers),
                    std::move(handler)
                );
            },
            token,
            this->self,
            std::vector<boost::asio::const_buffer>{
                boost::asio::buffer_sequence_begin(buffers),
                boost::asio::buffer_sequence_end(buffers)
            }
        );
    }

    /// @brief Tear down the network stream
    auto close() -> void
    {
        self->close();
    }
};
