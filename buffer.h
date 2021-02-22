#ifndef BUFFER_H
#define BUFFER_H

#include <uv.h>

void buffer_close(uv_buf_t const *buf);
void buffer_init(uv_buf_t *buf, size_t n);
void append_buffer(uv_buf_t *dst, ssize_t n, uv_buf_t const *src);

#endif
