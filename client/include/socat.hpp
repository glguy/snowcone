/**
 * @file socat.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief TCP connections via socat
 *
 */
#pragma once

#include <uv.h>

#include "uv.hpp"

/**
 * @brief Pipes for communicating with socat
 */
struct socat_pipes {
    /**
     * @brief Network socket
     */
    HandlePointer<uv_pipe_t> irc;

    /**
     * @brief stderr pipe
     */
    HandlePointer<uv_pipe_t> err;
};

/**
 * @brief Spawn a new socat process
 *
 * @param loop Current libuv loop
 * @param socat Connection string
 * @return network pipe and stderr pipe
 * @throws UV_error failed to spawn process
 */
socat_pipes socat_wrapper(uv_loop_t *loop, char const* socat);
