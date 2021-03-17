#ifndef TLS_HELPER_H
#define TLS_HELPER_H

#include <uv.h>

void tls_wrapper(uv_loop_t *loop, char const* socat_arg, int sock);

#endif
