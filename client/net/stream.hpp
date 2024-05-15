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
template <typename Executor, typename... Ts>
class Stream : private std::variant<Ts...>
{
    using base_type = std::variant<Ts...>;

    auto cases(auto f)
    {
        return std::visit(f, *static_cast<base_type*>(this));
    }

public:
    using base_type::base_type;
    using base_type::emplace;

    // AsyncReadStream and AsyncWriteStream type requirement
    using executor_type = Executor;

    /// @brief Get executor associated with this stream
    auto get_executor() -> executor_type
    {
        return cases([](auto &&x) -> executor_type {
            return x.get_executor();
        });
    }

    /// @brief AsyncReadStream method
    /// @param buffers Buffers to read into
    /// @param token Completion token for read operation
    /// @return Return determined by completion token
    template <
        typename MutableBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token
            = boost::asio::default_completion_token_t<executor_type>
        >
    auto async_read_some(
        MutableBufferSequence &&buffers,
        Token &&token = boost::asio::default_completion_token_t<executor_type>{}
    ) {
        return cases([&](auto &&x) {
            return x.async_read_some(std::forward<MutableBufferSequence>(buffers), std::forward<Token>(token));
        });
    }

    /// @brief AsyncWriteStream method
    /// @param buffers Buffers to write from
    /// @param token Completion token for write operation
    /// @return Return determined by completion token
    template <
        typename ConstBufferSequence,
        boost::asio::completion_token_for<void(boost::system::error_code, std::size_t)> Token
            = boost::asio::default_completion_token_t<executor_type>
        >
    auto async_write_some(
        ConstBufferSequence &&buffers,
        Token &&token = boost::asio::default_completion_token_t<executor_type>{}
    ) {
        return cases([&](auto &&x) {
            return x.async_write_some(std::forward<ConstBufferSequence>(buffers), std::forward<Token>(token));
        });
    }

    /// @brief Gracefully tear down the network stream
    auto close() -> void;
};

using CommonStream = Stream<boost::asio::any_io_executor, boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
extern template class Stream<boost::asio::any_io_executor, boost::asio::ip::tcp::socket, boost::asio::ssl::stream<boost::asio::ip::tcp::socket>>;
