#pragma once

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <cstddef>
#include <variant>

/// @brief Abstraction over a choice of Boost ASIO stream types.
///
/// This class template abstracts over multiple Boost ASIO stream types, allowing for
/// unified AsyncReadStream and AsyncWriteStream operations that dispatch to the
/// underlying stream representation.
///
/// @tparam Executor Type of the executor associated with the stream.
/// @tparam Ts... Stream types satisfying AsyncReadStream and AsyncWriteStream named type requirements.
template <typename Executor, typename... Ts>
class Stream : private std::variant<Ts...>
{
    using base_type = std::variant<Ts...>;

    /// @brief Apply a callable to the currently active stream variant.
    /// @tparam F Type of the callable.
    /// @param f The callable to apply.
    /// @return The result of the callable.
    template <typename F>
    auto cases(F&& f)
    {
        return std::visit(std::forward<F>(f), static_cast<base_type&>(*this));
    }

public:
    using base_type::base_type;
    using base_type::emplace;

    // The type of the executor associated with the stream.
    using executor_type = Executor;

    /// @brief Get the executor associated with this stream.
    /// @return The executor associated with the stream.
    auto get_executor() -> executor_type
    {
        return cases([](auto&& x) -> executor_type {
            return x.get_executor();
        });
    }

    /// @brief Initiates an asynchronous read operation.
    /// @tparam MutableBufferSequence Type of the buffer sequence.
    /// @tparam Token Type of the completion token.
    /// @param buffers The buffer sequence into which data will be read.
    /// @param token The completion token for the read operation.
    /// @return The result determined by the completion token.
    template <
        typename MutableBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token
        = boost::asio::default_completion_token_t<executor_type>>
    auto async_read_some(
        MutableBufferSequence&& buffers,
        Token&& token = boost::asio::default_completion_token_t<executor_type> {}
    )
    {
        return cases([&buffers, &token](auto&& x) {
            return x.async_read_some(std::forward<MutableBufferSequence>(buffers), std::forward<Token>(token));
        });
    }

    /// @brief Initiates an asynchronous write operation.
    /// @tparam ConstBufferSequence Type of the buffer sequence.
    /// @tparam Token Type of the completion token.
    /// @param buffers The buffer sequence from which data will be written.
    /// @param token The completion token for the write operation.
    /// @return The result determined by the completion token.
    template <
        typename ConstBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token
        = boost::asio::default_completion_token_t<executor_type>>
    auto async_write_some(
        ConstBufferSequence&& buffers,
        Token&& token = boost::asio::default_completion_token_t<executor_type> {}
    )
    {
        return cases([&buffers, &token](auto&& x) {
            return x.async_write_some(std::forward<ConstBufferSequence>(buffers), std::forward<Token>(token));
        });
    }

    /// @brief Gracefully tear down the network stream
    auto close() -> void;
};

// Define a common stream type that can be used with TCP or TLS over TCP.
using CommonStream = Stream<
    boost::asio::any_io_executor,
    boost::asio::ip::tcp::socket,
    boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;

extern template class Stream<
    boost::asio::any_io_executor,
    boost::asio::ip::tcp::socket,
    boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
