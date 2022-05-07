#include "read-line.hpp"

#include "uv.hpp"

#include <algorithm>
#include <cstring>
#include <iterator>

void readline_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
    auto const d = static_cast<readline_data*>(handle->data);
    buf->base = d->end;
    buf->len = std::distance(d->end, std::end(d->buffer));
}

void readline_read_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf)
{
    auto const d = static_cast<readline_data*>(stream->data);

    if (nread < 0)
    {
        d->cb(stream, nullptr);
        uv_close_xx(stream, [](auto handle) {
            delete static_cast<readline_data*>(handle->data);
            delete handle;
        });
        return;
    }

    std::advance(d->end, nread);
    auto cursor = std::begin(d->buffer);
    auto nl = std::find(cursor, d->end, '\n');
    if (d->end != nl) {
        do {
            *nl = '\0';
            d->cb(stream, cursor);
            cursor = std::next(nl);
            nl = std::find(cursor, d->end, '\n');
        } while (d->end != nl);
        d->end = std::copy(cursor, d->end, std::begin(d->buffer));
    }
}
