#pragma once

#include "stream.hpp"

auto stream_close(boost::asio::ip::tcp::socket& stream) -> void;

template <typename T>
auto stream_close(boost::asio::ssl::stream<T>& stream) -> void
{
    stream_close(stream.next_layer());
}

template <typename Executor, typename... Ts>
auto Stream<Executor, Ts...>::close() -> void
{
    cases([](auto&& x) { stream_close(x); });
}
