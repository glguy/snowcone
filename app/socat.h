#ifndef SOCAT_H
#define SOCAT_H

#include <uv.h>

uv_stream_t * socat_wrapper(uv_loop_t *loop, char const* socat_arg);

#endif
