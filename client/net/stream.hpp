#pragma once

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace websocket { class LineStream; }

/// The type-erased interface of one concrete stream (socket, TLS, WebSocket)
class StreamBase
{
public:
    using Sig = void(boost::system::error_code, std::size_t);
    virtual ~StreamBase() = default;
    /// Read some bytes into buffers, completing with the count read
    virtual auto async_read_some(std::vector<boost::asio::mutable_buffer> buffers, boost::asio::any_completion_handler<Sig> handler) -> void = 0;
    /// Write some bytes from buffers, completing with the count accepted
    virtual auto async_write_some(std::vector<boost::asio::const_buffer> buffers, boost::asio::any_completion_handler<Sig> handler) -> void = 0;
    /// Close abruptly, without any protocol shutdown; pending operations
    /// complete with an error
    virtual auto close() -> void = 0;

    /// Why the peer ended the stream, when the protocol says; otherwise empty
    virtual auto close_reason() const -> std::string { return {}; }
};

/// A handle to the current outermost stream of a connection. Copies share
/// the same StreamBase; a reset or upgrade replaces this handle's with a new
/// one, which for an upgrade wraps a copy of the old handle.
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

    /// An empty stream: reads and writes need a reset first (they must not be
    /// started on an empty one); close does nothing
    Stream(boost::asio::io_context& io_context)
        : io_context{&io_context}
        , self{}
    {
    }

    /// @brief Reset stream to a new, unopened TCP socket, dropping this
    /// handle's previous stream
    /// @return Reference to internal socket object
    auto reset_ip() -> boost::asio::ip::tcp::socket&;

    /// @brief Reset stream to a new, unopened local (Unix domain) socket,
    /// dropping this handle's previous stream
    /// @return Reference to internal socket object
    auto reset_local() -> boost::asio::local::stream_protocol::socket&;

    /// @brief Wrap the current stream (any socket or proxy tunnel) in TLS.
    /// @param ctx TLS context to configure the new SSL object from
    /// @return Reference to internal stream object, before its handshake
    auto upgrade(boost::asio::ssl::context& ctx) -> boost::asio::ssl::stream<Stream>&;

    /// @brief Upgrade the stream into a WebSocket carrying IRC lines.
    /// @return Reference to internal stream object, before its handshake
    auto upgrade_websocket() -> websocket::LineStream&;

    /// @brief This stream, as Asio's lowest layer (for ssl::stream)
    /// @return Reference to this Stream, not to a socket
    auto lowest_layer() -> lowest_layer_type&
    {
        return *this;
    }

    /// @brief This stream, as Asio's lowest layer (for ssl::stream)
    /// @return Reference to this Stream, not to a socket
    auto lowest_layer() const -> lowest_layer_type const&
    {
        return *this;
    }

    /// @brief Get the executor associated with this stream.
    /// @return The executor associated with the stream.
    auto get_executor() const noexcept -> executor_type
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

    /// @brief Tear down the network stream abruptly; does nothing if empty
    auto close() -> void
    {
        if (self)
        {
            self->close();
        }
    }

    /// @brief Why the peer ended the stream, when the protocol says
    /// @return Description, or empty when there is none
    auto close_reason() const -> std::string
    {
        return self ? self->close_reason() : std::string{};
    }
};
