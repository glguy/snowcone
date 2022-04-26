#include <string.h>

#include "read-line.hpp"

namespace {
void alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
    auto const d = static_cast<readline_data*>(handle->data);
    buf->base = d->buffer + d->used;
    buf->len = sizeof d->buffer - d->used - 1; // always save a byte for NUL
}

void read_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf)
{
    auto const d = static_cast<readline_data*>(stream->data);

    if (nread < 0)
    {
        d->cb(stream, NULL);
        uv_close(reinterpret_cast<uv_handle_t*>(stream), [](auto handle) {
            delete static_cast<readline_data*>(handle->data);
            delete handle;
        });
        return;
    }

    d->used += nread;
    d->buffer[d->used] = '\0';

    char *cursor = d->buffer;
    char *start;

    while(start = strsep(&cursor, "\n"), NULL != cursor)
    {
        d->cb(stream, start);
    }

    d->used = strlen(start);
    memmove(d->buffer, start, d->used);
}
}

int readline_start(uv_stream_t *stream, line_cb *on_line) {
    stream->data = new readline_data(on_line);
    return uv_read_start(stream, alloc_cb, read_cb);
}