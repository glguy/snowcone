#pragma once

#include "stream.hpp"

auto stream_close(boost::asio::ip::tcp::socket& stream) -> void;

template <typename T>
auto stream_close(boost::asio::ssl::stream<T>& stream) -> void
{
    stream_close(stream.next_layer());
}

template <typename... Ts>
auto Stream<Ts...>::close() -> void
{
    std::visit([](auto&& x){ stream_close(x); }, base());
}
