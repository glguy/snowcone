#include <string.h>

#include "read-line.h"
#include "buffer.h"

static void readline_close_cb(uv_handle_t *handle)
{
    struct readline_data *d = handle->data;
    buffer_close(&d->buffer);
    free(d);
    free(handle);
}

void readline_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf)
{
    struct app * const a = stream->loop->data;
    struct readline_data * const d = stream->data;

    if (nread < 0)
    {
        buffer_close(buf);
        uv_close((uv_handle_t *)stream, readline_close_cb);
        return;
    }

    append_buffer(&d->buffer, nread, buf);

    char *start = d->buffer.base;
    char *end;

    while ((end = strchr(start, '\n')))
    {
        *end++ = '\0';
        d->cb(d->cb_data, start);
        start = end;
    }

    memmove(d->buffer.base, start, strlen(start) + 1);
}
