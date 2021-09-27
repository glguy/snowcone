#ifndef SOCAT_H
#define SOCAT_H

#include <uv.h>

int socat_wrapper(uv_loop_t *loop, char const* socat_arg, uv_stream_t *stream);

#endif
