#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>

#include <boost/asio.hpp>

#include <base64.hpp>

#include <string>
#include <string_view>

#include "proxyauth.hpp"

namespace httpconnect {

auto encode_basic_auth(socks5::UsernamePasswordCredential const& auth) -> std::string;

using Signature = void(boost::system::error_code);
namespace http = boost::beast::http;

struct HttpErrCategory : boost::system::error_category
{
    char const* name() const noexcept override;
    std::string message(int) const override;
};

extern HttpErrCategory const theHttpErrCategory;

namespace detail {
    auto make_http_error(int status) -> boost::system::error_code;

    /// host:port in authority-form; IPv6 literals are bracketed, and a zone
    /// separator is percent-encoded as RFC 6874 requires
    auto authority(std::string_view host, uint16_t port) -> std::string;
}

/// Largest CONNECT response header block accepted (Beast's default header limit)
constexpr std::size_t max_response_size = 8 * 1024;

// Storing this in a unique_ptr ensures that moving around the composite action
// doesn't relocated the fields. This is important at a minimum because req
// merely points to target
struct State
{
    /// @brief Target hostname
    std::string target;
    http::request<http::empty_body> req;
    std::string response_bytes;
    socks5::Auth auth;
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
        state_->req.set(http::field::user_agent, "snowcone");

        if (auto * basic = std::get_if<socks5::UsernamePasswordCredential>(&state_->auth)) {
            state_->req.set(http::field::proxy_authorization, encode_basic_auth(*basic));
        }

        auto& req = state_->req; // ensure we dereference this before moving it
        http::async_write(stream_, req, std::bind_front(std::move(self), ReqSent{}));
    }

    template <typename Self>
    auto step(Self& self, ReqSent) -> void
    {
        auto& bytes = state_->response_bytes; // dereference before std::move

        // read a byte at a time until \r\n\r\n is found; the cap stops a
        // proxy that never ends its headers from exhausting memory
        boost::asio::async_read(
            stream_,
            boost::asio::dynamic_buffer(bytes, max_response_size),
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
        boost::system::error_code ec;
        http::response_parser<http::empty_body> parser;

        parser.skip(true);
        parser.put(boost::asio::buffer(state_->response_bytes), ec);

        if (not ec)
        {
            auto const status = parser.get().result();
            auto const status_class = http::to_status_class(status);
            if (status_class != http::status_class::successful)
            {
                ec = detail::make_http_error(static_cast<int>(status));
            }
        }

        return self.complete(ec);
    }
};

template <
    typename AsyncStream,
    boost::asio::completion_token_for<Signature> CompletionToken>
auto async_connect(
    AsyncStream& socket,
    std::string host,
    uint16_t const port,
    socks5::Auth auth,
    CompletionToken&& token
)
{
    auto state = std::make_unique<State>();
    state->target = detail::authority(host, port);
    state->auth = std::move(auth);
    return boost::asio::async_compose<CompletionToken, Signature>(HttpConnectImpl<AsyncStream>{socket, std::move(state)}, token, socket);
}

}
