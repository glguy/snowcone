#include <string.h>

#include "read-line.hpp"
#include "uv.hpp"

void readline_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
    auto const d = static_cast<readline_data*>(handle->data);
    buf->base = d->buffer + d->used;
    buf->len = sizeof d->buffer - d->used - 1; // always save a byte for NUL
}

void readline_read_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf)
{
    auto const d = static_cast<readline_data*>(stream->data);

    if (nread < 0)
    {
        d->cb(stream, nullptr);
        uv_close_xx(stream, [](auto handle) {
            delete static_cast<readline_data*>(handle->data);
            free(handle);
        });
        return;
    }

    d->used += nread;
    d->buffer[d->used] = '\0';

    char *cursor = d->buffer;
    char *start;

    while(start = strsep(&cursor, "\n"), nullptr != cursor)
    {
        d->cb(stream, start);
    }

    d->used = strlen(start);
    memmove(d->buffer, start, d->used);
}
