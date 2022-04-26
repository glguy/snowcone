#ifndef WRITE_H
#define WRITE_H

#include <stdlib.h>
#include <uv.h>

void to_write(uv_stream_t *data, char const* msg, size_t n);

#endif
