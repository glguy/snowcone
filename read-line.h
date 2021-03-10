#ifndef READ_LINE_H
#define READ_LINE_H

#include <uv.h>
#include "app.h"

struct readline_data
{
  uv_stream_t *write_data;
  void (*cb)(void *, char*);
  void *cb_data;
  uv_buf_t buffer;
};

void readline_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf);

#endif
