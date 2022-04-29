#ifndef SOCAT_H
#define SOCAT_H

#include <uv.h>

int socat_wrapper(uv_loop_t *loop, char const* socat, uv_pipe_t **irc_stream, uv_pipe_t **error_stream);

#endif
