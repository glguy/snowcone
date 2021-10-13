#include <string.h>

#include "read-line.h"

static void readline_close_cb(uv_handle_t *handle)
{
    free(handle->data);
    free(handle);
}

void readline_alloc(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
    struct readline_data * const d = handle->data;
    buf->base = d->buffer + d->used;
    buf->len = sizeof d->buffer - d->used - 1; // always save a byte for NUL
}

void readline_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf)
{
    struct readline_data * const d = stream->data;

    if (nread < 0)
    {
        d->read(d->read_data, NULL);
        uv_close((uv_handle_t *)stream, readline_close_cb);
        return;
    }

    d->used += nread;
    d->buffer[d->used] = '\0';

    char *cursor = d->buffer;
    char *start;

    while(start = strsep(&cursor, "\n"), NULL != cursor)
    {
        d->read(d->read_data, start);
    }

    d->used = strlen(start);
    memmove(d->buffer, start, d->used);
}
