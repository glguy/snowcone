#include "irc_connection.hpp"

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <variant>

class tls_irc_connection : public irc_connection
{
    using tls_socket = boost::asio::ssl::stream<tcp_socket>;
    tls_socket socket_;

public:
    tls_irc_connection(
        boost::asio::io_context &io_context,
        boost::asio::ssl::context &ssl_context,
        lua_State *const L);

    auto write_thread() -> void override;

    auto read_awaitable(
        boost::asio::mutable_buffer const& buffers
    ) -> boost::asio::awaitable<std::size_t> override;

    auto connect(
        boost::asio::ip::tcp::resolver::results_type const& endpoints,
        std::string const& verify,
        std::string_view socks_host,
        uint16_t socks_port
    ) -> boost::asio::awaitable<std::string> override;

    auto close() -> boost::system::error_code override;
};

struct BuildContextFailure
{
    const char * operation;
    boost::system::error_code error;
};

auto build_ssl_context(
    std::string const& client_cert,
    std::string const& client_key,
    std::string const& client_key_password
) -> std::variant<boost::asio::ssl::context, BuildContextFailure>;
