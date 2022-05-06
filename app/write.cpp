#include "write.hpp"

#include "uv.hpp"

#include <uv.h>

#include <algorithm>
#include <cstdlib>
#include <iterator>
#include <memory>

struct Request {
    uv_write_t write;
    std::unique_ptr<char[]> body;
    uv_buf_t const buf;

    Request(char const* msg, size_t n)
    : write {}    
    , body(std::make_unique<char[]>(n))
    , buf {body.get(), n}
    {
        write.data = this;
        std::copy_n(msg, n, body.get());
    }
};

void to_write(uv_stream_t *stream, char const* msg, size_t n)
{
    auto req = new Request(msg, n);
    uvok(uv_write(&req->write, stream, &req->buf, 1, [](auto write, auto status){
        delete static_cast<Request*>(write->data);
    }));
}
