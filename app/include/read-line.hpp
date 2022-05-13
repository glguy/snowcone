/**
 * @file read-line.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Line-oriented buffer for reading from libuv streams
 * 
 */

#pragma once

#include "app.hpp"
#include "uv.hpp"

#include <uv.h>

#include <array>
#include <concepts>
#include <iterator>

/**
 * @brief Callback type for complete lines with newline stripped.
 * 
 */
using line_cb = void(app*, char*);

/**
 * @brief Callback type on end of stream
 * 
 */
using done_cb = void(app*);

namespace {

struct readline_data
{
    using buffer_type = std::array<char, 32768>;

    line_cb* on_line;
    done_cb* on_done;
    uv_close_cb on_delete;
    buffer_type::iterator end;
    buffer_type buffer;

    readline_data(line_cb *on_line, done_cb *on_done, uv_close_cb on_delete)
    : on_line(on_line), on_done(on_done), on_delete(on_delete)
    , end(std::begin(buffer))
    {}

    uv_buf_t allocate() const {
      return uv_buf_init(end, std::end(buffer) - end);
    }
};

inline void readline_read_cb(uv_stream_t* stream, ssize_t nread, uv_buf_t const* buf)
{
    auto const a = static_cast<app*>(stream->loop->data);
    auto const d = static_cast<readline_data*>(stream->data);

    if (nread < 0)
    {
        auto on_delete = d->on_delete;
        delete d;
        uv_close(handle_cast(stream), on_delete);
        d->on_done(a);
    } else {
        // remember start of this chunk; there should be no newline before it
        auto chunk = d->end;

        // advance end iterator to end of current chunk
        std::advance(d->end, nread);

        auto cursor = std::begin(d->buffer);
        auto nl = std::find(chunk, d->end, '\n');
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
}

} // namespace

/**
 * @brief Install line-oriented callbacks for reading from stream
 *
 * This implementation takes ownership of the stream's data member.
 *
 * @param stream Open stream
 * @param on_line Callback for each line of stream
 * @param on_done Callback for stream close event
 * @param on_delete Deallocation callback
 */
inline void readline_start(uv_stream_t* stream, line_cb *on_line, done_cb *on_done, uv_close_cb on_delete) {
    stream->data = new readline_data(on_line, on_done, on_delete);
    uvok(uv_read_start(
        stream,
      
        [](uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf) {
            *buf = static_cast<readline_data*>(handle->data)->allocate();
        },
    
        readline_read_cb));
}
