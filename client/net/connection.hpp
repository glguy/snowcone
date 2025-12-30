#pragma once

#include "stream.hpp"

#include <socks5.hpp>

#include <boost/asio.hpp>

#include <openssl/evp.h>
#include <openssl/x509.h>

#include <functional>
#include <memory>
#include <optional>
#include <vector>

struct lua_State;

template <typename T, auto UpRef(T *) -> int, auto Free(T *) -> void>
class Ref {
    struct Deleter { auto operator()(T * const ptr) -> void { Free(ptr); }};
    std::unique_ptr<T, Deleter> obj;
public:
    Ref() = default;
    Ref(T* t) : obj{t} { if (t) UpRef(t); }
    auto get() const noexcept -> T* { return obj.get(); }
};

struct TlsLayer {
    Ref<X509, X509_up_ref, X509_free> client_cert;
    Ref<EVP_PKEY, EVP_PKEY_up_ref, EVP_PKEY_free> client_key;
    std::string verify;
    std::string sni;
};

struct SocksLayer {
    std::string host;
    std::uint16_t port;
    socks5::Auth auth;
};

struct Settings
{
    std::string host;
    std::uint16_t port;
    std::vector<std::variant<TlsLayer, SocksLayer>> layers;
};

class connection final : public std::enable_shared_from_this<connection>
{
public:
    static std::size_t const irc_buffer_size = 131'072;

private:
    Stream stream_;
    boost::asio::ip::tcp::resolver resolver_;

    /// @brief The bytes held for async_write
    std::vector<char> sending_;

    /// @brief The bytes accumulated for the next write
    std::vector<char> send_;

public:
    connection(boost::asio::io_context&);

    auto operator=(connection const&) -> connection& = delete;
    auto operator=(connection&&) -> connection& = delete;
    connection(connection const&) = delete;
    connection(connection&&) = delete;

    auto static create(boost::asio::io_context& io_context) -> std::shared_ptr<connection>
    {
        return std::make_shared<connection>(io_context);
    }

    auto get_stream() -> Stream&
    {
        return stream_;
    }

    // Queue messages for writing
    /**
     * @brief Write a message to the output stream
     *
     * @param msg The string to write including any needed line-terminators
     */
    auto write(std::string_view msg) -> void;

    /**
     * @brief Abruptly close the connection.
     * 
     */
    auto close() -> void;

    /**
     * @brief Initiate a connection to the IRC server
     * 
     * @param settings Parameters needed to establish a text stream with the server.
     * @return Space-separated, key=value pairs describing the connection
     */
    auto connect(Settings settings) -> boost::asio::awaitable<std::string>;

private:
    // There's data now, actually write it
    auto write_actual() -> void;
};
