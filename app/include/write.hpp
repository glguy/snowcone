/**
 * @file write.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Wrapper for scheduling writes to streams
 * 
 */

#pragma once

#include <uv.h>

#include <algorithm>
#include <cstddef>
#include <memory>

namespace {

struct Request {
    uv_write_t write;
    std::unique_ptr<char[]> body;
    uv_buf_t const buf;

    Request(std::size_t n)
    : write {}    
    , body(std::make_unique<char[]>(n))
    , buf {body.get(), n}
    {
        write.data = this;
    }
};

inline std::size_t buffer_needed(char const* msg, std::size_t n) {
    return n;
}

template<typename ...Args>
std::size_t buffer_needed(char const* msg, std::size_t n, Args... args) {
    return n + buffer_needed(args...);
}

inline void fills(char* dest, char const* msg, std::size_t n) {
    std::copy_n(msg, n, dest);
}

template<typename ...Args>
void fills(char* dest, char const* msg, std::size_t n, Args... args) {
    fills(std::copy_n(msg, n, dest), args...);
}

} // namespace

/**
 * @brief Write one or more buffers to a stream.
 * 
 * @tparam Bufs 
 * @param stream Open output stream
 * @param bufs Pairs of buffers specified with char* and size_t
 */
template<typename ...Bufs>
void to_write(uv_stream_t* stream, Bufs... bufs)
{
    auto req = std::make_unique<Request>(buffer_needed(bufs...));
    fills(req->body.get(), bufs...);
    uvok(uv_write(&req->write, stream, &req->buf, 1, [](auto write, auto status){
        delete static_cast<Request*>(write->data);
    }));
    req.release();
}
