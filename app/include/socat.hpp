/**
 * @file socat.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief TCP connections via socat
 * 
 */
#pragma once

#include <uv.h>

#include <optional>

/**
 * @brief Pipes for communicating with socat
 */
struct socat_pipes {
    /**
     * @brief Network socket
     */
    uv_pipe_t *irc;

    /**
     * @brief stderr pipe
     */
    uv_pipe_t *err;
};

/**
 * @brief Spawn a new socat process
 * 
 * @param loop Current libuv loop
 * @param socat Connection string
 * @return std::optional<socat_pipes> On success returns network pipe and stderr pipe
 */
std::optional<socat_pipes> socat_wrapper(uv_loop_t *loop, char const* socat);
