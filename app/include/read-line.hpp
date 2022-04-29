#ifndef READ_LINE_H
#define READ_LINE_H

#include <uv.h>

#include <concepts>

#include "app.hpp"

typedef void line_cb(uv_stream_t *, char*);

namespace {
struct readline_data
{
  line_cb *cb;
  size_t used;
  char buffer[65000];

  readline_data(line_cb *cb)
  : cb(cb)
  , used(0)
  , buffer()
  {

  }
};
}

void readline_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf);
void readline_read_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf);

template <typename T>
concept IsStream =
  std::same_as<T, uv_tcp_t> ||
  std::same_as<T, uv_pipe_t> ||
  std::same_as<T, uv_tty_t> ||
  std::same_as<T, uv_stream_t>;

template <typename T> requires IsStream<T>
auto readline_start(T* stream, line_cb *on_line) -> void {
    stream->data = new readline_data(on_line);
    uvok(uv_read_start(reinterpret_cast<uv_stream_t*>(stream), readline_alloc_cb, readline_read_cb));
}

#endif
