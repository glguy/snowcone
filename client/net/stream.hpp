#pragma once

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <cstdint>
#include <functional>
#include <span>
#include <string>

class AnyStream
{
protected:
    using Sig = void(boost::system::error_code, std::size_t);
    using handler_type = boost::asio::any_completion_handler<Sig>;
    using mutable_buffers = std::span<const boost::asio::mutable_buffer>;
    using const_buffers = std::span<const boost::asio::const_buffer>;

    virtual auto async_read_some_(mutable_buffers, handler_type) -> void = 0;
    virtual auto async_write_some_(const_buffers, handler_type) -> void = 0;

public:
    virtual ~AnyStream() = default;

    // AsyncReadStream and AsyncWriteStream type requirement
    using executor_type = boost::asio::any_io_executor;
    virtual auto get_executor() noexcept -> executor_type = 0;

    // AsyncReadStream type requirement
    template <
        typename MutableBufferSequence,
        boost::asio::completion_token_for<Sig> Token>
    auto async_read_some(
        MutableBufferSequence &&buffers,
        Token &&token)
    {
        using namespace std::placeholders;
        return boost::asio::async_initiate<Token, Sig>(
            std::bind(&AnyStream::async_read_some_, _2, _3, _1),
            token,
            this,
            mutable_buffers{
                boost::asio::buffer_sequence_begin(buffers),
                boost::asio::buffer_sequence_end(buffers)});
    }

    // AsyncWriteStream type requirement
    template <
        typename ConstBufferSequence,
        boost::asio::completion_token_for<Sig> Token>
    auto async_write_some(
        ConstBufferSequence &&buffers,
        Token &&token)
    {
        using namespace std::placeholders;
        return boost::asio::async_initiate<Token, Sig>(
            std::bind(&AnyStream::async_write_some_, _2, _3, _1),
            token,
            this,
            const_buffers{
                boost::asio::buffer_sequence_begin(buffers),
                boost::asio::buffer_sequence_end(buffers)});
    }

    // Gracefully tear down the network stream
    virtual auto close() -> void = 0;
};

class TcpStream final : public AnyStream
{
    boost::asio::ip::tcp::socket stream_;

    auto async_read_some_(mutable_buffers, handler_type) -> void override;
    auto async_write_some_(const_buffers, handler_type) -> void override;

public:
    TcpStream(boost::asio::ip::tcp::socket &&stream)
        : stream_{std::move(stream)}
    {
    }

    auto get_executor() noexcept -> executor_type override
    {
        return stream_.get_executor();
    }

    auto get_stream() noexcept -> boost::asio::ip::tcp::socket&
    {
        return stream_;
    }

    auto close() -> void override;
};

template <typename S>
class TlsStream final : public AnyStream
{
    boost::asio::ssl::stream<S> stream_;

    auto async_read_some_(mutable_buffers buffers, handler_type handler) -> void override;
    auto async_write_some_(const_buffers buffers, handler_type handler) -> void override;

public:

    TlsStream(boost::asio::ssl::stream<S> &&stream)
        : stream_{std::move(stream)}
    {
    }

    auto get_executor() noexcept -> executor_type override
    {
        return stream_.get_executor();
    }

    auto get_stream() noexcept -> boost::asio::ssl::stream<S>&
    {
        return stream_;
    }

    auto close() -> void override;
    auto set_buffer_size(std::size_t const size) -> void;
};

extern template class TlsStream<boost::asio::ip::tcp::socket>;
