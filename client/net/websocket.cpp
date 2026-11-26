#include "websocket.hpp"
#include "utf8.hpp"

#include <string_view>
#include <utility>

auto teardown(boost::beast::role_type, Stream& stream, boost::system::error_code& ec) -> void
{
    stream.close();
    ec = {};
}

namespace websocket {

namespace {

/// The length of the longest prefix of `s` that is valid UTF-8
auto valid_utf8_prefix(std::string_view const s) -> std::size_t
{
    std::size_t i = 0;
    while (i < s.size())
    {
        if (static_cast<unsigned char>(s[i]) < 0x80)
        {
            i++;
        }
        else if (auto const n = utf8_sequence_length(s.substr(i)))
        {
            i += n;
        }
        else
        {
            break;
        }
    }
    return i;
}

/// Replace `text` with `line`, each byte not part of a valid UTF-8
/// sequence replaced by U+FFFD
auto assign_utf8(std::string& text, std::string_view line) -> void
{
    text.clear();
    for (;;)
    {
        auto const n = valid_utf8_prefix(line);
        text.append(line.substr(0, n));
        line.remove_prefix(n);
        if (line.empty())
        {
            return;
        }
        text.append("\xef\xbf\xbd");
        line.remove_prefix(1);
    }
}

} // namespace

LineStream::LineStream(Stream next)
    : ws_{std::move(next)}
{
}

/// The composed operation of async_read_some: Start reads a message only
/// when none is buffered, Received appends its "\n", and either way the
/// buffered bytes are then copied out
struct LineStream::ReadOp
{
    LineStream& stream;
    std::vector<boost::asio::mutable_buffer> buffers;
    enum class Step { Start, Received, Ready } step = Step::Start;

    /// Run the next step, on initiation and as each read completes
    template <typename Self>
    auto operator()(Self& self, boost::system::error_code const error = {}, std::size_t = 0) -> void
    {
        auto& in = stream.in_;
        switch (step)
        {
        case Step::Start:
            step = in.size() == 0 ? Step::Received : Step::Ready;
            if (step == Step::Received)
            {
                stream.ws_.async_read(in, std::move(self));
            }
            else
            {
                // Complete as if from an operation, never from the initiation
                boost::asio::post(stream.ws_.get_executor(), std::move(self));
            }
            return;

        case Step::Received:
            if (error)
            {
                self.complete(error, 0);
                return;
            }
            boost::asio::buffer_copy(in.prepare(1), boost::asio::buffer("\n", 1));
            in.commit(1);
            break;

        case Step::Ready:
            break;
        }

        auto const n = boost::asio::buffer_copy(buffers, in.data());
        in.consume(n);
        self.complete({}, n);
    }
};

/// The composed operation of async_write_some: Start appends the buffers to
/// out_, then each complete line is sent as a message in turn (Sent), and
/// the operation completes when no complete line is left
struct LineStream::WriteOp
{
    LineStream& stream;
    std::vector<boost::asio::const_buffer> buffers;
    std::size_t accepted = 0;
    /// Bytes of out_ that the message in flight takes up, with its line ending
    std::size_t in_flight = 0;
    enum class Step { Start, Sent, Done } step = Step::Start;

    /// Run the next step, on initiation and as each message is sent
    template <typename Self>
    auto operator()(Self& self, boost::system::error_code const error = {}, std::size_t = 0) -> void
    {
        auto& out = stream.out_;
        switch (step)
        {
        case Step::Start:
            for (auto const& buffer : buffers)
            {
                out.append(static_cast<char const*>(buffer.data()), buffer.size());
                accepted += buffer.size();
            }
            buffers.clear();
            break;

        case Step::Sent:
            out.erase(0, in_flight);
            if (error)
            {
                self.complete(error, 0);
                return;
            }
            break;

        case Step::Done:
            self.complete({}, accepted);
            return;
        }

        // A message can't contain CR or LF, so either one ends a line. The
        // empty line between the two of "\r\n" is dropped, as is any other:
        // an empty message is not an IRC line.
        for (;;)
        {
            auto const end = out.find_first_of("\r\n");
            if (end == std::string::npos)
            {
                break;
            }
            if (end == 0)
            {
                out.erase(0, 1);
                continue;
            }
            in_flight = end + 1;
            step = Step::Sent;
            std::string_view const line{out.data(), end};
            if (stream.ws_.text() && valid_utf8_prefix(line) != line.size())
            {
                assign_utf8(stream.text_, line);
                stream.ws_.async_write(boost::asio::buffer(stream.text_), std::move(self));
            }
            else
            {
                stream.ws_.async_write(boost::asio::buffer(line), std::move(self));
            }
            return;
        }

        if (step == Step::Start)
        {
            // Complete as if from an operation, never from the initiation
            step = Step::Done;
            boost::asio::post(stream.ws_.get_executor(), std::move(self));
            return;
        }
        self.complete({}, accepted);
    }
};

auto LineStream::async_read_some(
    std::vector<boost::asio::mutable_buffer> buffers,
    boost::asio::any_completion_handler<StreamBase::Sig> handler
) -> void
{
    boost::asio::async_compose<decltype(handler), StreamBase::Sig>(
        ReadOp{*this, std::move(buffers)}, handler, ws_
    );
}

auto LineStream::async_write_some(
    std::vector<boost::asio::const_buffer> buffers,
    boost::asio::any_completion_handler<StreamBase::Sig> handler
) -> void
{
    boost::asio::async_compose<decltype(handler), StreamBase::Sig>(
        WriteOp{*this, std::move(buffers)}, handler, ws_
    );
}

auto LineStream::close() -> void
{
    ws_.next_layer().close();
}

auto LineStream::close_reason() const -> std::string
{
    auto const& reason = ws_.reason();
    if (not reason)
    {
        return {};
    }
    auto result = "WebSocket closed by the server with code " + std::to_string(reason.code);
    if (not reason.reason.empty())
    {
        result += " (";
        result += std::string_view{reason.reason.data(), reason.reason.size()};
        result += ")";
    }
    return result;
}

} // namespace websocket
