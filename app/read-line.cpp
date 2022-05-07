#include "read-line.hpp"

#include "uv.hpp"

#include <algorithm>
#include <cstring>
#include <iterator>
#include <string_view>
#include <fstream>

void readline_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
    auto const d = static_cast<readline_data*>(handle->data);
    buf->base = d->end;
    buf->len = std::distance(d->end, std::end(d->buffer));
}

void readline_read_cb(uv_stream_t* stream, ssize_t nread, uv_buf_t const* buf)
{
    auto const a = static_cast<app*>(stream->loop->data);
    auto const d = static_cast<readline_data*>(stream->data);

    if (nread < 0)
    {
        delete d;
        uv_close_delete(stream);
        d->cb(a, nullptr);
        return;
    }

    std::advance(d->end, nread);
    auto cursor = std::begin(d->buffer);
    auto nl = std::find(cursor, d->end, '\n');
    if (d->end != nl) {
        do {
            *nl = '\0';
            d->cb(a, cursor);
            cursor = std::next(nl);
            nl = std::find(cursor, d->end, '\n');
        } while (d->end != nl);
        d->end = std::copy(cursor, d->end, std::begin(d->buffer));
    }
}
