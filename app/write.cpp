#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include <uv.h>
#include <vector>

#include "uv.hpp"
#include "write.hpp"

struct Request {
    uv_write_t write;
    std::vector<char> body;
    uv_buf_t buf;

    Request(char const* msg, size_t n)
    : write {}    
    , body(msg, msg+n)
    , buf {body.data(), n}
    {}
};

void to_write(uv_stream_t *stream, char const* msg, size_t n)
{
    auto req = new Request(msg, n);
    req->write.data = req;
    uvok(uv_write(&req->write, stream, &req->buf, 1, [](auto write, auto status){
        delete static_cast<Request*>(write->data);
    }));
}
