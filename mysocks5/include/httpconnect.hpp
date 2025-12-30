#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>

#include <boost/asio.hpp>

#include <string>

using namespace std::literals::string_view_literals;
namespace httpconnect {

using Signature = void(boost::system::error_code);
namespace http = boost::beast::http;

// Storing this in a unique_ptr ensures that moving around the composite action
// doesn't relocated the fields. This is important at a minimum because req
// merely points to target
struct State
{
    /// @brief Target hostname
    std::string target;
    http::request<http::empty_body> req;
    std::string response_bytes;
};

template <typename AsyncStream>
struct HttpConnectImpl
{
    AsyncStream& stream_;

    std::unique_ptr<State> state_;

    struct Start
    {
    };

    struct ReqSent
    {
    };

    struct RspRecv
    {
    };

    template <typename Self, typename State = Start>
    auto operator()(
        Self& self,
        State state = {},
        boost::system::error_code const error = {},
        std::size_t = 0
    ) -> void
    {
        if (error)
        {
            self.complete(error);
        }
        else
        {
            step(self, state);
        }
    }

    template <typename Self>
    auto step(Self& self, Start) -> void
    {
        state_->req.version(11);
        state_->req.method(http::verb::connect);
        state_->req.target(state_->target);
        state_->req.set(http::field::host, state_->target);
        state_->req.set(http::field::user_agent, BOOST_BEAST_VERSION_STRING);

        auto& req = state_->req; // ensure we dereference this before moving it
        http::async_write(stream_, req, std::bind_front(std::move(self), ReqSent{}));
    }

    template <typename Self>
    auto step(Self& self, ReqSent) -> void
    {
        auto& bytes = state_->response_bytes; // dereference before std::move

        // read a byte at a time until \r\n\r\n is found
        boost::asio::async_read(
            stream_,
            boost::asio::dynamic_buffer(bytes),
            [&bytes](
                boost::system::error_code const& ec,
                std::size_t bytes_transfered
            ) -> std::size_t {
                return ec || bytes.ends_with("\r\n\r\n") ? 0 : 1;
            },
            std::bind_front(std::move(self), RspRecv{})
        );
    }

    template <typename Self>
    auto step(Self& self, RspRecv) -> void
    {
        http::response_parser<http::empty_body> parser;
        boost::system::error_code ec;
        parser.put(boost::asio::buffer(state_->response_bytes), ec);

        if (ec)
        {
            return self.complete(ec);
        }

        if (parser.get().result() == http::status::ok)
        {
            return self.complete({});
        }

        return self.complete(http::error::bad_status);
    }
};

template <
    typename AsyncStream,
    boost::asio::completion_token_for<Signature> CompletionToken>
auto async_connect(
    AsyncStream& socket,
    std::string host,
    uint16_t const port,
    CompletionToken&& token
)
{
    host += ":";
    host += std::to_string(port);
    auto state = std::make_unique<State>();
    state->target = host;
    return boost::asio::async_compose<CompletionToken, Signature>(HttpConnectImpl<AsyncStream>{socket, std::move(state)}, token, socket);
}

}
