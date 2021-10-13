#ifndef READ_LINE_H
#define READ_LINE_H

#include <uv.h>
#include "app.h"

struct readline_data
{
  uv_stream_t *write_data;
  void (*read)(void *, char*);
  void *read_data;
  size_t used;
  char buffer[65000];
};

void readline_alloc(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf);
void readline_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf);

#endif
