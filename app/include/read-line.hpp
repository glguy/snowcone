#pragma once

#include "app.hpp"
#include "uv.hpp"

#include <uv.h>

#include <array>
#include <concepts>

using line_cb = void(app*, char*);
using done_cb = void(app*);

namespace {

struct readline_data
{
    using buffer_type = std::array<char, 32768>;

    line_cb* on_line;
    done_cb* on_done;
    buffer_type::iterator end;
    buffer_type buffer;

    readline_data(line_cb *on_line, done_cb *on_done)
    : on_line(on_line), on_done(on_done)
    , end(std::begin(buffer))
    {}
};

} // namespace

void readline_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf);
void readline_read_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf);

// stream must be allocated with malloc since readline won't know what type to delete it at.
template <typename T> requires IsStream<T>
auto readline_start(T* stream, line_cb *on_line, done_cb *on_done) -> void {
    stream->data = new readline_data(on_line, on_done);
    uvok(uv_read_start(stream_cast(stream), readline_alloc_cb, readline_read_cb));
}
