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
        d->on_done(a);
        return;
    }

    std::advance(d->end, nread);
    auto cursor = std::begin(d->buffer);
    auto nl = std::find(cursor, d->end, '\n');
    if (d->end != nl) {
        do {
            // detect and support carriage return before newline
            if (cursor < nl) {
                auto cr = std::prev(nl);
                if ('\r' == *cr) {
                    *cr = '\0';
                }
            }
            *nl = '\0';
            d->on_line(a, cursor);
            cursor = std::next(nl);
            nl = std::find(cursor, d->end, '\n');
        } while (d->end != nl);

        // move remaining incomplete line to the front of the buffer
        d->end = std::copy(cursor, d->end, std::begin(d->buffer));
    }
}
