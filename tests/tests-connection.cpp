#include "connection.hpp"

#include "cloexec.hpp"

#include <gtest/gtest.h>

#include <boost/asio/ssl.hpp>

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>

#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

#include <array>
#include <cstdio>
#include <cstdint>
#include <future>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {

namespace asio = boost::asio;
using tcp = asio::ip::tcp;

auto loopback_acceptor(asio::io_context& io) -> tcp::acceptor
{
    tcp::acceptor acceptor{io, {asio::ip::address_v4::loopback(), 0}};
    return acceptor;
}

auto settings_for(tcp::acceptor const& acceptor) -> Settings
{
    return Settings{
        .base = IpLayer{
            .host = "127.0.0.1",
            .port = acceptor.local_endpoint().port(),
        },
        .layers = {},
    };
}

auto settings_for_host(std::string host, tcp::acceptor const& acceptor) -> Settings
{
    return Settings{
        .base = IpLayer{
            .host = std::move(host),
            .port = acceptor.local_endpoint().port(),
        },
        .layers = {},
    };
}

auto echo_server(
    tcp::acceptor& acceptor,
    std::size_t const request_size,
    std::string response
) -> asio::awaitable<std::string>
{
    tcp::socket socket{co_await asio::this_coro::executor};
    co_await acceptor.async_accept(socket, asio::use_awaitable);

    std::string request(request_size, '\0');
    co_await asio::async_read(socket, asio::buffer(request), asio::use_awaitable);
    co_await asio::async_write(socket, asio::buffer(response), asio::use_awaitable);
    co_return request;
}

auto http_proxy_server(
    tcp::acceptor& acceptor,
    std::string response
) -> asio::awaitable<std::string>
{
    tcp::socket socket{co_await asio::this_coro::executor};
    co_await acceptor.async_accept(socket, asio::use_awaitable);

    std::string request;
    co_await asio::async_read_until(
        socket,
        asio::dynamic_buffer(request),
        "\r\n\r\n",
        asio::use_awaitable
    );
    co_await asio::async_write(socket, asio::buffer(response), asio::use_awaitable);

    std::array<char, 4> payload{};
    co_await asio::async_read(socket, asio::buffer(payload), asio::use_awaitable);
    std::string const reply = "PONG";
    co_await asio::async_write(socket, asio::buffer(reply), asio::use_awaitable);
    co_return request;
}

auto connect_and_read(
    std::shared_ptr<connection> const& conn,
    Settings settings,
    std::string post_connect_write,
    std::size_t const response_size
) -> asio::awaitable<std::string>
{
    co_await conn->connect(std::move(settings));
    conn->write(post_connect_write);

    std::string response(response_size, '\0');
    co_await asio::async_read(
        conn->get_stream(),
        asio::buffer(response),
        asio::use_awaitable
    );
    co_return response;
}

// A SOCKS5 proxy that accepts without authentication, records the CONNECT
// request (from VER through DST.PORT), then tunnels one PING/PONG exchange.
auto socks5_proxy_server(tcp::acceptor& acceptor) -> asio::awaitable<std::vector<std::uint8_t>>
{
    tcp::socket socket{co_await asio::this_coro::executor};
    co_await acceptor.async_accept(socket, asio::use_awaitable);

    std::array<std::uint8_t, 3> hello{};
    co_await asio::async_read(socket, asio::buffer(hello), asio::use_awaitable);
    std::array<std::uint8_t, 2> const method{5, 0};
    co_await asio::async_write(socket, asio::buffer(method), asio::use_awaitable);

    std::vector<std::uint8_t> request(4);
    co_await asio::async_read(socket, asio::buffer(request), asio::use_awaitable);
    std::size_t address_size = 0;
    switch (request[3])
    {
    case 1: address_size = 4; break;
    case 4: address_size = 16; break;
    case 3: {
        request.resize(5);
        co_await asio::async_read(socket, asio::buffer(&request[4], 1), asio::use_awaitable);
        address_size = request[4];
        break;
    }
    default: throw std::runtime_error{"bad ATYP"};
    }
    auto const offset = request.size();
    request.resize(offset + address_size + 2);
    co_await asio::async_read(socket, asio::buffer(&request[offset], address_size + 2), asio::use_awaitable);

    // Succeeded, bound to 192.0.2.1:4321
    std::array<std::uint8_t, 10> const reply{5, 0, 0, 1, 192, 0, 2, 1, 0x10, 0xe1};
    co_await asio::async_write(socket, asio::buffer(reply), asio::use_awaitable);

    std::array<char, 4> payload{};
    co_await asio::async_read(socket, asio::buffer(payload), asio::use_awaitable);
    std::string const pong = "PONG";
    co_await asio::async_write(socket, asio::buffer(pong), asio::use_awaitable);
    co_return request;
}

auto connect_through_socks5_proxy(
    std::shared_ptr<connection> const& conn,
    tcp::acceptor const& acceptor,
    std::string target
) -> asio::awaitable<std::string>
{
    Settings settings{
        .base = IpLayer{
            .host = "127.0.0.1",
            .port = acceptor.local_endpoint().port(),
        },
    };
    settings.layers.emplace_back(SocksLayer{
        .host = std::move(target),
        .port = 6667,
        .auth = socks5::NoCredential{},
    });
    co_await conn->connect(std::move(settings));
    conn->write("PING");

    std::string response(4, '\0');
    co_await asio::async_read(
        conn->get_stream(),
        asio::buffer(response),
        asio::use_awaitable
    );
    co_return response;
}

auto socks5_request_for(std::string target) -> std::vector<std::uint8_t>
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);

    auto server_result = asio::co_spawn(io, socks5_proxy_server(acceptor), asio::use_future);
    auto client_result = asio::co_spawn(
        io,
        connect_through_socks5_proxy(conn, acceptor, std::move(target)),
        asio::use_future
    );
    io.run();

    EXPECT_EQ(client_result.get(), "PONG");
    return server_result.get();
}

// A proxy that sends headers without ever ending them, then waits for the
// client to hang up. Returns how many header bytes it sent.
auto endless_http_proxy_server(tcp::acceptor& acceptor) -> asio::awaitable<std::size_t>
{
    tcp::socket socket{co_await asio::this_coro::executor};
    co_await acceptor.async_accept(socket, asio::use_awaitable);

    std::string request;
    co_await asio::async_read_until(
        socket,
        asio::dynamic_buffer(request),
        "\r\n\r\n",
        asio::use_awaitable
    );

    std::string response = "HTTP/1.1 200 Connection Established\r\n";
    while (response.size() < 64 * 1024)
    {
        response += "X-Filler: 0123456789abcdef0123456789abcdef\r\n";
    }
    co_await asio::async_write(socket, asio::buffer(response), asio::use_awaitable);

    std::array<char, 1> byte{};
    auto const [ec, n] = co_await asio::async_read(socket, asio::buffer(byte), asio::as_tuple(asio::use_awaitable));
    static_cast<void>(ec);
    static_cast<void>(n);
    co_return response.size();
}

auto connect_through_http_proxy_expecting_error(
    std::shared_ptr<connection> const& conn,
    tcp::acceptor const& acceptor
) -> asio::awaitable<boost::system::error_code>
{
    Settings settings{
        .base = IpLayer{
            .host = "127.0.0.1",
            .port = acceptor.local_endpoint().port(),
        },
    };
    settings.layers.emplace_back(HttpLayer{
        .host = "irc.example",
        .port = 6667,
        .auth = socks5::NoCredential{},
    });

    boost::system::error_code result;
    try
    {
        co_await conn->connect(std::move(settings));
    }
    catch (boost::system::system_error const& error)
    {
        result = error.code();
    }
    conn->close();
    co_return result;
}

auto connect_through_http_proxy(
    std::shared_ptr<connection> const& conn,
    tcp::acceptor const& acceptor,
    std::string target = "irc.example"
) -> asio::awaitable<std::string>
{
    Settings settings{
        .base = IpLayer{
            .host = "127.0.0.1",
            .port = acceptor.local_endpoint().port(),
        },
    };
    settings.layers.emplace_back(HttpLayer{
        .host = std::move(target),
        .port = 6667,
        .auth = socks5::NoCredential{},
    });
    co_await conn->connect(std::move(settings));
    conn->write("PING");

    std::string response(4, '\0');
    co_await asio::async_read(
        conn->get_stream(),
        asio::buffer(response),
        asio::use_awaitable
    );
    co_return response;
}

auto connect_then_close_during_read(
    asio::io_context& io,
    std::shared_ptr<connection> const& conn,
    Settings settings
) -> asio::awaitable<boost::system::error_code>
{
    co_await conn->connect(std::move(settings));

    asio::post(io, [conn] { conn->close(); });

    std::array<char, 1> byte{};
    boost::system::error_code error;
    co_await conn->get_stream().async_read_some(
        asio::buffer(byte),
        asio::redirect_error(asio::use_awaitable, error)
    );
    co_return error;
}

TEST(Connection, QueuesEarlyAndConnectedWritesAndReceivesResponse)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);
    std::string const early_request = "NICK test\r\n";
    std::string const connected_request = "USER test 0 * :Test User\r\n";
    std::string const request = early_request + connected_request;
    std::string const response = ":server 001 test :welcome\r\n";

    auto server_result = asio::co_spawn(
        io,
        echo_server(acceptor, request.size(), response),
        asio::use_future
    );

    conn->write(early_request);
    auto client_result = asio::co_spawn(
        io,
        connect_and_read(conn, settings_for(acceptor), connected_request, response.size()),
        asio::use_future
    );

    io.run();

    EXPECT_EQ(client_result.get(), response);
    EXPECT_EQ(server_result.get(), request);
}

TEST(Connection, ConnectsToIpv4ListenerUsingLocalhost)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);
    std::string const request = "HELLO";
    std::string const response = "WELCOME";

    auto server_result = asio::co_spawn(
        io,
        echo_server(acceptor, request.size(), response),
        asio::use_future
    );
    auto client_result = asio::co_spawn(
        io,
        connect_and_read(conn, settings_for_host("localhost", acceptor), request, response.size()),
        asio::use_future
    );

    io.run();

    EXPECT_EQ(client_result.get(), response);
    EXPECT_EQ(server_result.get(), request);
}

TEST(Connection, HttpConnectAcceptsHeaderOnly200AndTransfersTunnelData)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);

    auto server_result = asio::co_spawn(
        io,
        http_proxy_server(acceptor, "HTTP/1.1 200 Connection Established\r\n\r\n"),
        asio::use_future
    );
    auto client_result = asio::co_spawn(
        io,
        connect_through_http_proxy(conn, acceptor),
        asio::use_future
    );

    io.run();

    EXPECT_EQ(client_result.get(), "PONG");
    EXPECT_TRUE(server_result.get().starts_with("CONNECT irc.example:6667 HTTP/1.1\r\n"));
}

TEST(Connection, HttpConnectAcceptsOther2xxStatus)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);

    auto server_result = asio::co_spawn(
        io,
        http_proxy_server(acceptor, "HTTP/1.1 201 Created\r\n\r\n"),
        asio::use_future
    );
    auto client_result = asio::co_spawn(
        io,
        connect_through_http_proxy(conn, acceptor),
        asio::use_future
    );

    io.run();

    EXPECT_EQ(client_result.get(), "PONG");
    EXPECT_TRUE(server_result.get().starts_with("CONNECT irc.example:6667 HTTP/1.1\r\n"));
}

TEST(Connection, Socks5SendsIpv4LiteralAsAddress)
{
    std::vector<std::uint8_t> const expected{5, 1, 0, 1, 192, 0, 2, 7, 0x1a, 0x0b};
    EXPECT_EQ(socks5_request_for("192.0.2.7"), expected);
}

TEST(Connection, Socks5SendsIpv6LiteralAsAddress)
{
    std::vector<std::uint8_t> const expected{
        5, 1, 0, 4,
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
        0x1a, 0x0b,
    };
    EXPECT_EQ(socks5_request_for("2001:db8::1"), expected);
}

TEST(Connection, Socks5SendsHostnameAsDomainName)
{
    std::vector<std::uint8_t> const expected{
        5, 1, 0, 3, 11, 'i', 'r', 'c', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x1a, 0x0b,
    };
    EXPECT_EQ(socks5_request_for("irc.example"), expected);
}

TEST(Connection, Socks5SendsScopedIpv6LiteralAsDomainName)
{
    std::vector<std::uint8_t> const expected{
        5, 1, 0, 3, 12, 'f', 'e', '8', '0', ':', ':', '1', '%', 'e', 't', 'h', '0', 0x1a, 0x0b,
    };
    EXPECT_EQ(socks5_request_for("fe80::1%eth0"), expected);
}

auto http_connect_request_for(std::string target) -> std::string
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);

    auto server_result = asio::co_spawn(
        io,
        http_proxy_server(acceptor, "HTTP/1.1 200 Connection Established\r\n\r\n"),
        asio::use_future
    );
    auto client_result = asio::co_spawn(
        io,
        connect_through_http_proxy(conn, acceptor, std::move(target)),
        asio::use_future
    );
    io.run();

    EXPECT_EQ(client_result.get(), "PONG");
    return server_result.get();
}

TEST(Connection, HttpConnectBracketsIpv6Literal)
{
    auto const request = http_connect_request_for("2001:db8::1");
    EXPECT_TRUE(request.starts_with("CONNECT [2001:db8::1]:6667 HTTP/1.1\r\n")) << request;
    EXPECT_NE(request.find("\r\nHost: [2001:db8::1]:6667\r\n"), std::string::npos) << request;
}

TEST(Connection, HttpConnectEncodesIpv6Zone)
{
    auto const request = http_connect_request_for("fe80::1%eth0");
    EXPECT_TRUE(request.starts_with("CONNECT [fe80::1%25eth0]:6667 HTTP/1.1\r\n")) << request;
}

TEST(Connection, HttpConnectLeavesIpv4LiteralBare)
{
    auto const request = http_connect_request_for("192.0.2.7");
    EXPECT_TRUE(request.starts_with("CONNECT 192.0.2.7:6667 HTTP/1.1\r\n")) << request;
}

TEST(TlsNames, VerifiesHostnamesAndAddressesAsGiven)
{
    EXPECT_EQ(tls_names::verification("irc.example"), "irc.example");
    EXPECT_EQ(tls_names::verification("192.0.2.7"), "192.0.2.7");
    EXPECT_EQ(tls_names::verification("2001:db8::1"), "2001:db8::1");
}

TEST(TlsNames, VerifiesScopedIpv6LiteralWithoutZone)
{
    EXPECT_EQ(tls_names::verification("fe80::1%eth0"), "fe80::1");
    EXPECT_EQ(tls_names::verification("fe80::1%7"), "fe80::1");
}

TEST(TlsNames, SendsHostnameAsServerName)
{
    EXPECT_EQ(tls_names::server_name("irc.example"), "irc.example");
}

TEST(TlsNames, SendsNoServerNameForIpLiteralsOrEmpty)
{
    EXPECT_EQ(tls_names::server_name("192.0.2.7"), std::nullopt);
    EXPECT_EQ(tls_names::server_name("2001:db8::1"), std::nullopt);
    EXPECT_EQ(tls_names::server_name("fe80::1%eth0"), std::nullopt);
    EXPECT_EQ(tls_names::server_name(""), std::nullopt);
}

auto resolved(
    std::optional<std::string_view> const verify,
    std::optional<std::string_view> const sni,
    std::string_view const host
) -> std::pair<std::string, std::string>
{
    auto names = tls_names::resolve(verify, sni, host);
    return {std::move(names.verify), std::move(names.sni)};
}

using Names = std::pair<std::string, std::string>;

TEST(TlsNames, BothDefaultToHost)
{
    EXPECT_EQ(resolved({}, {}, "irc.example"), (Names{"irc.example", "irc.example"}));
}

TEST(TlsNames, VerifyIsTheDefaultServerName)
{
    // Connecting by address while checking the certificate's name
    EXPECT_EQ(resolved("irc.example", {}, "192.0.2.7"), (Names{"irc.example", "irc.example"}));
}

TEST(TlsNames, ServerNameIsTheDefaultVerify)
{
    EXPECT_EQ(resolved({}, "irc.example", "localhost"), (Names{"irc.example", "irc.example"}));
}

TEST(TlsNames, BothGivenAreKept)
{
    EXPECT_EQ(resolved("cert.example", "front.example", "host"), (Names{"cert.example", "front.example"}));
}

TEST(TlsNames, EmptyNameTurnsOffOnlyItsOwnUse)
{
    EXPECT_EQ(resolved("", {}, "irc.example"), (Names{"", "irc.example"}));
    EXPECT_EQ(resolved({}, "", "irc.example"), (Names{"irc.example", ""}));
    EXPECT_EQ(resolved("", "", "irc.example"), (Names{"", ""}));
}

TEST(TlsNames, LocalSocketHasNoHostDefault)
{
    EXPECT_EQ(resolved("", {}, ""), (Names{"", ""}));
    EXPECT_EQ(resolved("irc.example", {}, ""), (Names{"irc.example", "irc.example"}));
}

TEST(Connection, HttpConnectRejectsOversizedResponse)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);

    auto server_result = asio::co_spawn(
        io,
        endless_http_proxy_server(acceptor),
        asio::use_future
    );
    auto client_result = asio::co_spawn(
        io,
        connect_through_http_proxy_expecting_error(conn, acceptor),
        asio::use_future
    );

    io.run();

    EXPECT_TRUE(client_result.get().failed());
    EXPECT_GT(server_result.get(), 8u * 1024u);
}

TEST(Connection, ClosingBeforeConnectAbortsConnect)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);
    conn->close();

    auto result = asio::co_spawn(
        io,
        conn->connect(settings_for(acceptor)),
        asio::use_future
    );
    io.run();

    try
    {
        static_cast<void>(result.get());
        FAIL() << "connect should fail after close";
    }
    catch (boost::system::system_error const& error)
    {
        EXPECT_EQ(error.code(), asio::error::operation_aborted);
    }
}

TEST(Connection, CancellingConnectBeforeItStartsAbortsConnect)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);
    asio::cancellation_signal cancellation;

    auto result = asio::co_spawn(
        io,
        conn->connect(settings_for(acceptor)),
        asio::bind_cancellation_slot(cancellation.slot(), asio::use_future)
    );
    cancellation.emit(asio::cancellation_type::all);
    io.run();

    try
    {
        static_cast<void>(result.get());
        FAIL() << "connect should fail after cancellation";
    }
    catch (boost::system::system_error const& error)
    {
        EXPECT_EQ(error.code(), asio::error::operation_aborted);
    }
}

TEST(Connection, RefusedConnectReportsError)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto settings = settings_for(acceptor);
    boost::system::error_code close_error;
    acceptor.close(close_error);
    ASSERT_FALSE(close_error);

    auto conn = connection::create(io);
    auto result = asio::co_spawn(io, conn->connect(std::move(settings)), asio::use_future);
    io.run();

    try
    {
        static_cast<void>(result.get());
        FAIL() << "connect should fail when no server is listening";
    }
    catch (boost::system::system_error const& error)
    {
        EXPECT_EQ(error.code(), asio::error::connection_refused);
    }
}

TEST(Connection, ClosingCancelsPendingRead)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    tcp::socket peer{io};
    boost::system::error_code accept_error;
    acceptor.async_accept(peer, [&accept_error](boost::system::error_code const error) {
        accept_error = error;
    });

    auto conn = connection::create(io);
    auto result = asio::co_spawn(
        io,
        connect_then_close_during_read(io, conn, settings_for(acceptor)),
        asio::use_future
    );
    io.run();

    ASSERT_FALSE(accept_error);
    EXPECT_EQ(result.get(), asio::error::operation_aborted);
}

auto happy_connect(
    tcp::socket& socket,
    std::string host,
    unsigned short const port,
    happy_eyeballs::CancellationSource& source
) -> asio::awaitable<tcp::endpoint>
{
    co_return co_await happy_eyeballs::async_connect(
        socket,
        std::move(host),
        std::to_string(port),
        source
    );
}

template <typename Future>
auto result_code(Future& future) -> boost::system::error_code
{
    try
    {
        static_cast<void>(future.get());
        return {};
    }
    catch (boost::system::system_error const& error)
    {
        return error.code();
    }
}

auto is_cloexec(int const fd) -> bool
{
    auto const flags = ::fcntl(fd, F_GETFD);
    return flags != -1 && (flags & FD_CLOEXEC) != 0;
}

auto connect_noting_close(
    std::shared_ptr<connection> conn,
    Settings settings,
    bool const& closed,
    bool& returned_after_close
) -> asio::awaitable<void>
{
    try
    {
        co_await conn->connect(std::move(settings));
        returned_after_close = closed;
    }
    catch (boost::system::system_error const&)
    {
        // aborted or failed: acceptable outcomes after close()
    }
}

// TLS: a test CA is made trusted through SSL_CERT_FILE, which the client's
// set_default_verify_paths honours

using PkeyPtr = std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)>;
using X509Ptr = std::unique_ptr<X509, decltype(&X509_free)>;

auto make_key() -> PkeyPtr
{
    return PkeyPtr{EVP_EC_gen("P-256"), EVP_PKEY_free};
}

auto add_extension(X509* const cert, X509* const issuer, int const nid, char const* const value) -> void
{
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, issuer, cert, nullptr, nullptr, 0);
    auto const ext = X509V3_EXT_conf_nid(nullptr, &ctx, nid, value);
    ASSERT_NE(ext, nullptr);
    X509_add_ext(cert, ext, -1);
    X509_EXTENSION_free(ext);
}

/// A certificate for `key`, signed by issuer (self-signed when null)
auto make_cert(EVP_PKEY* const key, char const* const cn, char const* const san, X509* issuer, EVP_PKEY* issuer_key) -> X509Ptr
{
    X509Ptr cert{X509_new(), X509_free};
    X509_set_version(cert.get(), X509_VERSION_3);
    ASN1_INTEGER_set(X509_get_serialNumber(cert.get()), 1);
    X509_gmtime_adj(X509_getm_notBefore(cert.get()), -60);
    X509_gmtime_adj(X509_getm_notAfter(cert.get()), 3600);
    X509_set_pubkey(cert.get(), key);
    auto const name = X509_NAME_new();
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, reinterpret_cast<unsigned char const*>(cn), -1, -1, 0);
    X509_set_subject_name(cert.get(), name);
    X509_NAME_free(name);
    if (not issuer)
    {
        issuer = cert.get();
        issuer_key = key;
    }
    X509_set_issuer_name(cert.get(), X509_get_subject_name(issuer));
    add_extension(cert.get(), issuer, NID_basic_constraints, san ? "critical,CA:FALSE" : "critical,CA:TRUE");
    if (san)
    {
        add_extension(cert.get(), issuer, NID_subject_alt_name, san);
    }
    X509_sign(cert.get(), issuer_key, EVP_sha256());
    return cert;
}

struct TlsFixture
{
    PkeyPtr ca_key = make_key();
    X509Ptr ca = make_cert(ca_key.get(), "snowcone test CA", nullptr, nullptr, nullptr);
    PkeyPtr server_key = make_key();
    X509Ptr server = make_cert(server_key.get(), "irc.example",
        "DNS:irc.example,IP:127.0.0.1,IP:::1", ca.get(), ca_key.get());
    PkeyPtr rogue_key = make_key();
    X509Ptr rogue = make_cert(rogue_key.get(), "irc.example", "DNS:irc.example", nullptr, nullptr);

    TlsFixture()
    {
        char path[] = "/tmp/snowcone-test-ca-XXXXXX";
        auto const fd = mkstemp(path);
        auto const file = fdopen(fd, "w");
        PEM_write_X509(file, ca.get());
        std::fclose(file);
        ca_path = path;
        setenv("SSL_CERT_FILE", path, 1);
    }

    ~TlsFixture()
    {
        unlink(ca_path.c_str());
    }

    std::string ca_path;
};

auto tls_fixture() -> TlsFixture&
{
    static TlsFixture fixture;
    return fixture;
}

/// Hex SHA-256 of the DER SubjectPublicKeyInfo of key
auto spki_sha256(EVP_PKEY* const key) -> std::string
{
    unsigned char* der = nullptr;
    auto const len = i2d_PUBKEY(key, &der);
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0;
    EVP_Digest(der, len, md, &md_len, EVP_sha256(), nullptr);
    OPENSSL_free(der);
    std::string hex;
    for (unsigned i = 0; i < md_len; ++i)
    {
        char buf[3];
        std::snprintf(buf, sizeof buf, "%02x", md[i]);
        hex += buf;
    }
    return hex;
}

struct TlsOutcome
{
    std::string client; // the connect result, or "error: " and the message
    std::optional<std::string> server_sni;
    std::optional<std::string> server_alpn; // the encoded list the client offered
};

/// Serve one TLS handshake with cert and key, then connect to it with tls
auto tls_connect(X509* const cert, EVP_PKEY* const key, TlsLayer tls) -> TlsOutcome
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto conn = connection::create(io);

    asio::ssl::context server_ctx{asio::ssl::context::tls_server};
    SSL_CTX_use_certificate(server_ctx.native_handle(), cert);
    SSL_CTX_use_PrivateKey(server_ctx.native_handle(), key);

    TlsOutcome outcome;

    // Only called when the client sends ALPN; selects nothing
    SSL_CTX_set_alpn_select_cb(
        server_ctx.native_handle(),
        [](SSL*, unsigned char const**, unsigned char*, unsigned char const* const in, unsigned int const inlen, void* const arg) -> int {
            static_cast<TlsOutcome*>(arg)->server_alpn.emplace(reinterpret_cast<char const*>(in), inlen);
            return SSL_TLSEXT_ERR_NOACK;
        },
        &outcome);

    asio::co_spawn(io, [&]() -> asio::awaitable<void> {
        asio::ssl::stream<tcp::socket> stream{co_await asio::this_coro::executor, server_ctx};
        co_await acceptor.async_accept(stream.next_layer(), asio::use_awaitable);
        boost::system::error_code ignored;
        co_await stream.async_handshake(stream.server, asio::redirect_error(asio::use_awaitable, ignored));
        if (auto const sni = SSL_get_servername(stream.native_handle(), TLSEXT_NAMETYPE_host_name))
        {
            outcome.server_sni = sni;
        }
    }, asio::detached);

    auto settings = settings_for(acceptor);
    settings.layers.push_back(std::move(tls));
    asio::co_spawn(io, [&]() -> asio::awaitable<void> {
        try
        {
            outcome.client = co_await conn->connect(std::move(settings));
        }
        catch (std::exception const& e)
        {
            outcome.client = std::string{"error: "} + e.what();
        }
        conn->close();
    }, asio::detached);

    io.run();
    return outcome;
}

auto tls_connect(TlsLayer tls) -> TlsOutcome
{
    auto& f = tls_fixture();
    return tls_connect(f.server.get(), f.server_key.get(), std::move(tls));
}

TEST(Tls, VerifiesHostname)
{
    auto const outcome = tls_connect({.verify = "irc.example", .sni = "irc.example"});
    EXPECT_FALSE(outcome.client.starts_with("error")) << outcome.client;
    EXPECT_EQ(outcome.server_sni, "irc.example");
}

TEST(Tls, FingerprintIsSha256OfSubjectPublicKeyInfo)
{
    auto const outcome = tls_connect({.verify = "irc.example", .sni = ""});
    auto const want = " tls=" + spki_sha256(tls_fixture().server_key.get());
    EXPECT_TRUE(outcome.client.ends_with(want)) << outcome.client;
}

TEST(Tls, ReportsHostnameMismatch)
{
    auto const outcome = tls_connect({.verify = "other.example", .sni = ""});
    EXPECT_NE(outcome.client.find("hostname mismatch"), std::string::npos) << outcome.client;
}

TEST(Tls, VerifiesIpAddresses)
{
    EXPECT_FALSE(tls_connect({.verify = "127.0.0.1", .sni = ""}).client.starts_with("error"));
    auto const outcome = tls_connect({.verify = "192.0.2.1", .sni = ""});
    EXPECT_NE(outcome.client.find("IP address mismatch"), std::string::npos) << outcome.client;
}

TEST(Tls, VerifiesScopedIpv6LiteralByAddress)
{
    auto const outcome = tls_connect({.verify = "::1%1", .sni = ""});
    EXPECT_FALSE(outcome.client.starts_with("error")) << outcome.client;
}

TEST(Tls, ReportsUntrustedCertificate)
{
    auto& f = tls_fixture();
    auto const outcome = tls_connect(f.rogue.get(), f.rogue_key.get(), {.verify = "irc.example", .sni = ""});
    EXPECT_NE(outcome.client.find("self-signed"), std::string::npos) << outcome.client;
}

TEST(Tls, EmptyVerifyAcceptsAnyCertificate)
{
    auto& f = tls_fixture();
    auto const outcome = tls_connect(f.rogue.get(), f.rogue_key.get(), {.verify = "", .sni = ""});
    EXPECT_FALSE(outcome.client.starts_with("error")) << outcome.client;
}

TEST(Tls, SendsNoServerNameForIpLiteralOrEmpty)
{
    EXPECT_EQ(tls_connect({.verify = "irc.example", .sni = "127.0.0.1"}).server_sni, std::nullopt);
    EXPECT_EQ(tls_connect({.verify = "irc.example", .sni = ""}).server_sni, std::nullopt);
}

TEST(Tls, SendsNoAlpnByDefault)
{
    auto const outcome = tls_connect({.verify = "irc.example", .sni = ""});
    EXPECT_FALSE(outcome.client.starts_with("error")) << outcome.client;
    EXPECT_EQ(outcome.server_alpn, std::nullopt);
}

TEST(Tls, SendsConfiguredAlpnInOrder)
{
    auto const outcome = tls_connect({.verify = "irc.example", .sni = "", .alpn = {"irc", "http/1.1"}});
    EXPECT_FALSE(outcome.client.starts_with("error")) << outcome.client;
    EXPECT_EQ(outcome.server_alpn, std::string{"\x03irc\x08http/1.1"});
}

TEST(OpenCloexec, TcpAndLocalSocketsAreCloseOnExec)
{
    asio::io_context io;
    boost::system::error_code error;

    tcp::socket tcp_socket{io};
    open_cloexec(tcp_socket, tcp::v4(), error);
    ASSERT_FALSE(error);
    ASSERT_TRUE(tcp_socket.is_open());
    EXPECT_TRUE(is_cloexec(tcp_socket.native_handle()));

    asio::local::stream_protocol::socket local_socket{io};
    open_cloexec(local_socket, asio::local::stream_protocol{}, error);
    ASSERT_FALSE(error);
    ASSERT_TRUE(local_socket.is_open());
    EXPECT_TRUE(is_cloexec(local_socket.native_handle()));
}

TEST(HappyEyeballs, ConnectedSocketIsCloseOnExec)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    tcp::socket socket{io};
    happy_eyeballs::CancellationSource source;

    auto result = asio::co_spawn(
        io,
        happy_connect(socket, "127.0.0.1", acceptor.local_endpoint().port(), source),
        asio::use_future
    );
    io.run();
    static_cast<void>(result.get());

    ASSERT_TRUE(socket.is_open());
    EXPECT_TRUE(is_cloexec(socket.native_handle()));
}

// close() may land at any point while connect() is suspended, including after
// the winning TCP attempt has been chosen but before the coroutine resumes.
// In every case connect() must not report success after close() was called.
TEST(Connection, CloseAtAnyPointDuringConnectNeverYieldsLiveConnection)
{
    for (int steps = 0; steps < 40; ++steps)
    {
        asio::io_context io;
        auto acceptor = loopback_acceptor(io);
        auto conn = connection::create(io);
        bool closed = false;
        bool returned_after_close = false;

        asio::co_spawn(
            io,
            connect_noting_close(conn, settings_for(acceptor), closed, returned_after_close),
            asio::detached
        );

        // Let exactly `steps` handlers run, then close between two handlers.
        for (int i = 0; i < steps && io.run_one() != 0; ++i)
        {
        }
        closed = true;
        conn->close();

        io.restart();
        io.run();

        EXPECT_FALSE(returned_after_close) << "connect() succeeded after close() following " << steps << " handlers";
    }
}

TEST(HappyEyeballs, MovesWinningSocketIntoCallersSocket)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    tcp::socket socket{io};
    happy_eyeballs::CancellationSource source;

    auto result = asio::co_spawn(
        io,
        happy_connect(socket, "127.0.0.1", acceptor.local_endpoint().port(), source),
        asio::use_future
    );
    io.run();

    auto const endpoint = result.get();
    EXPECT_EQ(endpoint, acceptor.local_endpoint());
    ASSERT_TRUE(socket.is_open());
    EXPECT_EQ(socket.remote_endpoint(), endpoint);
}

TEST(HappyEyeballs, ConnectsToIpv6LiteralDespiteIpv4ResolveFailure)
{
    asio::io_context io;
    boost::system::error_code listen_error;
    tcp::acceptor acceptor{io};
    acceptor.open(tcp::v6(), listen_error);
    if (not listen_error)
    {
        acceptor.bind({asio::ip::address_v6::loopback(), 0}, listen_error);
    }
    if (not listen_error)
    {
        acceptor.listen(asio::socket_base::max_listen_connections, listen_error);
    }
    if (listen_error)
    {
        GTEST_SKIP() << "IPv6 loopback unavailable: " << listen_error.message();
    }

    tcp::socket socket{io};
    happy_eyeballs::CancellationSource source;
    auto result = asio::co_spawn(
        io,
        happy_connect(socket, "::1", acceptor.local_endpoint().port(), source),
        asio::use_future
    );
    io.run();

    auto const endpoint = result.get();
    EXPECT_TRUE(endpoint.address().is_v6());
    EXPECT_TRUE(socket.is_open());
}

TEST(HappyEyeballs, ReportsConnectionRefusedOverResolveErrors)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto const port = acceptor.local_endpoint().port();
    acceptor.close();

    tcp::socket socket{io};
    happy_eyeballs::CancellationSource source;
    auto result = asio::co_spawn(
        io,
        happy_connect(socket, "localhost", port, source),
        asio::use_future
    );
    io.run();

    EXPECT_EQ(result_code(result), asio::error::connection_refused);
    EXPECT_FALSE(socket.is_open());
}

TEST(HappyEyeballs, ReportsHostNotFoundForUnresolvableName)
{
    asio::io_context io;
    tcp::socket socket{io};
    happy_eyeballs::CancellationSource source;
    auto result = asio::co_spawn(
        io,
        happy_connect(socket, "no-such-host.invalid", 6667, source),
        asio::use_future
    );
    io.run();

    auto const code = result_code(result);
    EXPECT_TRUE(code);
    EXPECT_NE(code, asio::error::operation_aborted);
}

TEST(HappyEyeballs, RejectsAlreadyOpenSocket)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    tcp::socket socket{io, tcp::v4()};
    happy_eyeballs::CancellationSource source;

    auto result = asio::co_spawn(
        io,
        happy_connect(socket, "127.0.0.1", acceptor.local_endpoint().port(), source),
        asio::use_future
    );
    io.run();

    EXPECT_EQ(result_code(result), asio::error::already_open);
}

TEST(HappyEyeballs, CoroutineCancellationBeforeStartAborts)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    tcp::socket socket{io};
    happy_eyeballs::CancellationSource source;
    asio::cancellation_signal cancellation;

    auto result = asio::co_spawn(
        io,
        happy_connect(socket, "127.0.0.1", acceptor.local_endpoint().port(), source),
        asio::bind_cancellation_slot(cancellation.slot(), asio::use_future)
    );
    cancellation.emit(asio::cancellation_type::all);
    io.run();

    EXPECT_EQ(result_code(result), asio::error::operation_aborted);
    EXPECT_FALSE(socket.is_open());
}

TEST(HappyEyeballs, CancelledSourceAbortsUntilReset)
{
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto const port = acceptor.local_endpoint().port();
    tcp::socket socket{io};
    happy_eyeballs::CancellationSource source;
    source.emit(asio::cancellation_type::terminal);

    auto aborted = asio::co_spawn(io, happy_connect(socket, "127.0.0.1", port, source), asio::use_future);
    io.run();
    EXPECT_EQ(result_code(aborted), asio::error::operation_aborted);

    // A later, weaker cancellation must not downgrade the sticky state.
    source.emit(asio::cancellation_type::partial);
    io.restart();
    auto still_aborted = asio::co_spawn(io, happy_connect(socket, "127.0.0.1", port, source), asio::use_future);
    io.run();
    EXPECT_EQ(result_code(still_aborted), asio::error::operation_aborted);

    source.reset();
    io.restart();
    auto connected = asio::co_spawn(io, happy_connect(socket, "127.0.0.1", port, source), asio::use_future);
    io.run();
    EXPECT_FALSE(result_code(connected));
    EXPECT_TRUE(socket.is_open());
}

// Intended to be run under ThreadSanitizer: cancellations race with
// resolution, connection attempts and completion across several threads.
TEST(HappyEyeballs, ConcurrentConnectsAndCancellationsComplete)
{
    struct Case
    {
        tcp::socket socket;
        happy_eyeballs::CancellationSource source;
        std::future<tcp::endpoint> result;

        explicit Case(asio::io_context& io)
            : socket{io}
        {
        }
    };

    constexpr std::size_t count = 64;
    asio::io_context io;
    auto acceptor = loopback_acceptor(io);
    auto const port = acceptor.local_endpoint().port();

    std::vector<std::unique_ptr<Case>> cases;
    for (std::size_t i = 0; i < count; ++i)
    {
        auto& c = cases.emplace_back(std::make_unique<Case>(io));
        c->result = asio::co_spawn(
            io,
            happy_connect(c->socket, i % 2 == 0 ? "127.0.0.1" : "localhost", port, c->source),
            asio::use_future
        );
    }

    {
        std::vector<std::jthread> threads;
        for (int i = 0; i < 4; ++i)
        {
            threads.emplace_back([&io] { io.run(); });
        }

        for (std::size_t i = 0; i < count; i += 2)
        {
            cases[i]->source.emit(asio::cancellation_type::all);
        }
    }

    for (auto const& c : cases)
    {
        auto const code = result_code(c->result);
        if (code)
        {
            EXPECT_EQ(code, asio::error::operation_aborted);
            EXPECT_FALSE(c->socket.is_open());
        }
        else
        {
            EXPECT_TRUE(c->socket.is_open());
        }
    }
}

} // namespace
