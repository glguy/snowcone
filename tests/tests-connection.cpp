#include "connection.hpp"

#include <gtest/gtest.h>

#include <array>
#include <future>
#include <string>
#include <utility>

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

auto connect_through_http_proxy(
    std::shared_ptr<connection> const& conn,
    tcp::acceptor const& acceptor
) -> asio::awaitable<std::string>
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

} // namespace
