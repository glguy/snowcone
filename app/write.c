#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include <uv.h>

#include "buffer.h"
#include "write.h"

struct request {
    uv_write_t write;
    uv_buf_t buf;
    char body[];
};

static void write_done(uv_write_t *write, int status);

void to_write(uv_stream_t *stream, char const* msg, size_t n)
{
    struct request *req = malloc(sizeof (struct request) + n);
    assert(req);

    req->buf.base = req->body;
    req->buf.len = n;
    memcpy(req->body, msg, n);

    req->write = (uv_write_t){ .data = req };
    uv_write(&req->write, stream, &req->buf, 1, write_done);
}

static void write_done(uv_write_t *write, int status)
{
    struct request *req = write->data;
    free(req);
}
