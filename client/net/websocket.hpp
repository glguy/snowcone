#pragma once

#include "stream.hpp"

#include <boost/asio.hpp>
#include <boost/beast/core/flat_buffer.hpp>
#include <boost/beast/core/role.hpp>
#include <boost/beast/websocket/stream.hpp>

#include <cstddef>
#include <string>
#include <vector>

// Beast finds how to close a WebSocket's next layer by argument-dependent
// lookup. Stream's teardown is an abrupt close, like connection::close.
inline auto beast_close_socket(Stream& stream) -> void
{
    stream.close();
}

auto teardown(boost::beast::role_type, Stream& stream, boost::system::error_code& ec) -> void;

template <typename TeardownHandler>
auto async_teardown(boost::beast::role_type, Stream& stream, TeardownHandler&& handler) -> void
{
    stream.close();
    boost::asio::post(
        stream.get_executor(),
        boost::asio::append(std::forward<TeardownHandler>(handler), boost::system::error_code{})
    );
}

namespace websocket {

/// The IRCv3 subprotocols, offered in this order by default. Binary
/// messages carry any bytes; text messages must be UTF-8.
inline constexpr char const* binary_subprotocol = "binary.ircv3.net";
inline constexpr char const* text_subprotocol = "text.ircv3.net";

/**
 * @brief A WebSocket carrying IRC as a byte stream of lines
 *
 * IRCv3 sends one IRC line per message, without its line ending. Reads give
 * each received message followed by "\n". Writes send each complete line as
 * one message without its line ending, and hold a trailing incomplete line
 * until the rest of it is written. A message can't contain CR or LF, so
 * either one ends a line, and empty lines are not sent. A text message
 * must be UTF-8, so in text mode each byte that isn't part of a valid
 * sequence is sent as U+FFFD.
 *
 * Supports one read and one write in progress at a time.
 */
class LineStream
{
    boost::beast::websocket::stream<Stream> ws_;

    /// Received bytes not yet read, ending in the "\n" added to a message
    boost::beast::flat_buffer in_;

    /// Written bytes not yet sent, the first line of them possibly in flight
    std::string out_;

    /// The text message in flight when its line in out_ isn't valid UTF-8:
    /// that line with each invalid byte replaced
    std::string text_;

    struct ReadOp;
    struct WriteOp;

public:
    explicit LineStream(Stream next);

    /// The WebSocket, for the handshake
    auto ws() -> boost::beast::websocket::stream<Stream>&
    {
        return ws_;
    }

    auto async_read_some(
        std::vector<boost::asio::mutable_buffer> buffers,
        boost::asio::any_completion_handler<StreamBase::Sig> handler
    ) -> void;

    auto async_write_some(
        std::vector<boost::asio::const_buffer> buffers,
        boost::asio::any_completion_handler<StreamBase::Sig> handler
    ) -> void;

    /// Close the stream underneath without a close frame
    auto close() -> void;

    /// The code and reason of the server's close frame, if one was received
    auto close_reason() const -> std::string;
};

} // namespace websocket
