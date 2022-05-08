#pragma once

#include <uv.h>

#include <cstdlib>
#include <memory>


namespace {

struct Request {
    uv_write_t write;
    std::unique_ptr<char[]> body;
    uv_buf_t const buf;

    Request(size_t n)
    : write {}    
    , body(std::make_unique<char[]>(n))
    , buf {body.get(), n}
    {
        write.data = this;
    }
};

size_t constexpr buffer_needed(char const* msg, size_t n) {
    return n;
}

template<typename ...Args>
size_t constexpr buffer_needed(char const* msg, size_t n, Args... args) {
    return n + buffer_needed(args...);
}

void fills(char* dest, char const* msg, size_t n) {
    std::copy_n(msg, n, dest);
}

template<typename ...Args>
void fills(char* dest, char const* msg, size_t n, Args... args) {
    fills(std::copy_n(msg, n, dest), args...);
}

} // namespace

template<typename ...Bufs>
void to_write(uv_stream_t *stream, Bufs... bufs)
{
    auto req = std::make_unique<Request>(buffer_needed(bufs...));
    fills(req->buf.base, bufs...);
    uvok(uv_write(&req->write, stream, &req->buf, 1, [](auto write, auto status){
        delete static_cast<Request*>(write->data);
    }));
    req.release();
}
