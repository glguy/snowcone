#pragma once

#include <uv.h>

#include <optional>

struct socat_pipes {
    uv_pipe_t *irc;
    uv_pipe_t *err;
};

std::optional<socat_pipes> socat_wrapper(uv_loop_t *loop, char const* socat);
