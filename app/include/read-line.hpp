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

#include <algorithm>
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

class readline_data
{
    using buffer_type = std::array<char, 32000>;
    buffer_type buffer;
    buffer_type::iterator end = std::begin(buffer);

    line_cb* on_line;
    done_cb* on_done;
    uv_close_cb on_delete;

public:
    readline_data(line_cb* on_line, done_cb* on_done, uv_close_cb on_delete) noexcept
    : on_line {on_line}, on_done {on_done}, on_delete {on_delete} {}

    uv_buf_t allocate() const noexcept {
        return uv_buf_init(end, std::end(buffer) - end);
    }
    
    void read_cb(uv_stream_t* stream, ssize_t nread, uv_buf_t const* buf) noexcept
    {
        auto const a = app::from_loop(stream->loop);

        if (nread < 0) {
            uv_close(handle_cast(stream), on_delete);
            on_done(a);
            delete this;
        } else {
            // remember start of this chunk; there should be no newline before it
            auto chunk = end;

            // advance end iterator to end of current chunk
            std::advance(end, nread);

            auto nl = std::find(chunk, end, '\n');
            if (end != nl) {
                auto cursor = std::begin(buffer);
                do {
                    // detect and support carriage return before newline
                    if (cursor < nl) {
                        auto cr = std::prev(nl);
                        if ('\r' == *cr) {
                            *cr = '\0';
                        }
                    }

                    *nl = '\0';
                    on_line(a, cursor);
                    cursor = std::next(nl);
                    nl = std::find(cursor, end, '\n');
                } while (end != nl);

                // move remaining incomplete line to the front of the buffer
                end = std::copy(cursor, end, std::begin(buffer));
            }
        }
    }
};

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
inline void readline_start(uv_stream_t* stream, line_cb* on_line, done_cb* on_done, uv_close_cb on_delete) {
    stream->data = new readline_data(on_line, on_done, on_delete);
    uvok(uv_read_start(
        stream,
      
        [](uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf) {
            *buf = static_cast<readline_data*>(handle->data)->allocate();
        },
    
        [](uv_stream_t* stream, ssize_t nread, uv_buf_t const* buf) {
            auto const d = static_cast<readline_data*>(stream->data);
            d->read_cb(stream, nread, buf);
        }));
}
