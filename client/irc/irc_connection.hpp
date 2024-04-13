#pragma once

#include <boost/asio.hpp>

#include <deque>
#include <functional>
#include <memory>
#include <optional>

#include "../net/stream.hpp"

struct lua_State;

class irc_connection final : public std::enable_shared_from_this<irc_connection>
{
public:
    using stream_type = CommonStream;
    static std::size_t const irc_buffer_size = 131'072;

private:
    boost::asio::steady_timer write_timer;
    lua_State *L;
    std::deque<int> write_refs;
    std::deque<boost::asio::const_buffer> write_buffers;
    stream_type stream_;

public:
    irc_connection(boost::asio::io_context&, lua_State *L);
    ~irc_connection();

    auto operator=(irc_connection const&) -> irc_connection& = delete;
    auto operator=(irc_connection &&) -> irc_connection& = delete;
    irc_connection(irc_connection const&) = delete;
    irc_connection(irc_connection &&) = delete;

    auto get_stream() -> stream_type&
    {
        return stream_;
    }

    auto set_stream(stream_type&& stream)
    {
        stream_ = std::move(stream);
    }

    auto get_lua() const -> lua_State*
    {
        return L;
    }

    // Queue messages for writing
    auto write(std::string_view cmd, int const ref) -> void;

    auto close() -> void { stream_.close(); }

    // Either write data now or wait for there to be data
    auto write_thread() -> void;

private:
    // There's data now, actually write it
    auto write_thread_actual() -> void;
};
