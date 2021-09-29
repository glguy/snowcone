#include <stdlib.h>
#include <string.h>

#include <uv.h>

#include "buffer.h"
#include "write.h"

static void write_done(uv_write_t *write, int status);

void to_write(uv_stream_t *stream, char const* msg, size_t n)
{
    uv_buf_t *buf = malloc(sizeof *buf);
    buffer_init(buf, n);
    memcpy(buf->base, msg, n);

    uv_write_t *req = malloc(sizeof *req);
    *req = (uv_write_t){ .data = buf };
    uv_write(req, stream, buf, 1, write_done);
}

static void write_done(uv_write_t *write, int status)
{
    uv_buf_t *buf = write->data;
    buffer_close(buf);
    free(buf);
    free(write);
}
