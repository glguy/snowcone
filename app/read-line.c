#include <string.h>

#include "buffer.h"
#include "read-line.h"

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
        d->read(d->read_data, NULL);
        buffer_close(buf);
        uv_close((uv_handle_t *)stream, readline_close_cb);
        return;
    }

    // This consumes and closes buf
    append_buffer(&d->buffer, nread, buf);

    char *cursor = d->buffer.base;
    char *start;

    while(start = strsep(&cursor, "\n"), NULL != cursor)
    {
        d->read(d->read_data, start);
    }

    memmove(d->buffer.base, start, strlen(start) + 1);
}
