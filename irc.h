#ifndef IRC_H
#define IRC_H

#include <uv.h>

#include "configuration.h"

void start_irc(uv_loop_t *loop, struct configuration *cfg);

#endif
