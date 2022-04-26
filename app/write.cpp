#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include <uv.h>
#include <vector>

#include "write.hpp"

struct Request {
    uv_write_t write;
    std::vector<char> body;
    uv_buf_t buf;

    Request(char const* msg, size_t n)
    : write()    
    , body(msg, msg+n)
    , buf()
    {
        buf.base = body.data();
        buf.len = n; 
    }
};

static void write_done(uv_write_t *write, int status);

void to_write(uv_stream_t *stream, char const* msg, size_t n)
{
    auto req = new Request(msg, n);
    int res = uv_write(&req->write, stream, &req->buf, 1, write_done);
    assert(0 == res);
}

static void write_done(uv_write_t *write, int status)
{
    delete reinterpret_cast<Request*>(write);
}
