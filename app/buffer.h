#ifndef BUFFER_H
#define BUFFER_H

#include <uv.h>

void buffer_close(uv_buf_t const *buf);
void buffer_init(uv_buf_t *buf, size_t n);
void append_buffer(uv_buf_t *dst, size_t n, uv_buf_t const *src);
void my_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf);

#endif
