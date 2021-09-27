#define _GNU_SOURCE

#include <spawn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <uv.h>

#include "socat.h"

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal);

int socat_wrapper(uv_loop_t *loop, char const* socat, uv_stream_t *stream)
{
    char const* argv[] = {"socat", "FD:3", socat, NULL};

    uv_stdio_container_t containers[] = {
        {.flags = UV_IGNORE},
        {.flags = UV_IGNORE},
        {.flags = UV_INHERIT_FD, .data.fd = STDERR_FILENO},
        {.flags = UV_CREATE_PIPE | UV_READABLE_PIPE | UV_WRITABLE_PIPE, .data.stream = stream}
    };

    uv_process_options_t options = {
        .file = "socat",
        .args = (char**)argv, // libuv doesn't actually write to these
        .exit_cb = socat_exit,
        .stdio_count = sizeof containers / sizeof *containers,
        .stdio = containers,
    };

    uv_process_t *process = malloc(sizeof *process);
    int result = uv_spawn(loop, process, &options);

    return result;
}

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal)
{
    free(process);
}
