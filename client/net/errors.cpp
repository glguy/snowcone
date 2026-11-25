#include "errors.hpp"

#include <boost/asio/error.hpp>
#include <boost/asio/ssl/error.hpp>
#include <boost/beast/http/error.hpp>

#include <openssl/err.h>

auto describe_error(boost::system::error_code const& ec) -> std::string
{
    namespace error = boost::asio::error;

    if (ec == error::eof || ec == boost::beast::http::error::end_of_stream)
    {
        return "connection closed by server";
    }
    if (ec == boost::asio::ssl::error::stream_truncated)
    {
        return "connection closed without TLS shutdown";
    }
    if (ec == error::connection_refused)
    {
        return "connection refused";
    }
    if (ec == error::connection_reset)
    {
        return "connection reset by server";
    }
    if (ec == error::timed_out)
    {
        return "connection timed out";
    }
    if (ec == error::network_unreachable)
    {
        return "network unreachable";
    }
    if (ec == error::host_unreachable)
    {
        return "host unreachable";
    }
    if (ec == error::host_not_found)
    {
        return "host name not found";
    }
    if (ec == error::host_not_found_try_again)
    {
        return "host name lookup failed, try again later";
    }
    if (ec == error::no_data)
    {
        return "host name has no addresses";
    }

    // Asio's message adds the OpenSSL library's name to the reason
    if (ec.category() == error::get_ssl_category())
    {
        if (auto const reason = ::ERR_reason_error_string(static_cast<unsigned int>(ec.value())))
        {
            return reason;
        }
    }

    return ec.message();
}
