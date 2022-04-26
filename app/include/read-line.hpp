#ifndef READ_LINE_H
#define READ_LINE_H

#include <uv.h>

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

int readline_start(uv_stream_t *stream, line_cb *on_line);

#endif
