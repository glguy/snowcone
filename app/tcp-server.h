#ifndef TCP_SERVER_H
#define TCP_SERVER_H

#include <uv.h>

void start_tcp_server(uv_loop_t *, char const*, char const*);

#endif
