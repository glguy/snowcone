#define _GNU_SOURCE

#include <spawn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <uv.h>

#include "socat.h"

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal);

static void free_handle(uv_handle_t *handle)
{
    free(handle);
}

uv_stream_t * socat_wrapper(uv_loop_t *loop, char const* socat)
{
    char const* argv[] = {"socat", "FD:3", socat, NULL};

    uv_pipe_t *stream = malloc(sizeof *stream);
    uv_pipe_init(loop, stream, 0);

    uv_stdio_container_t containers[] = {
        {.flags = UV_IGNORE},
        {.flags = UV_IGNORE},
        {.flags = UV_INHERIT_FD, .data.fd = STDERR_FILENO},
        {.flags = UV_CREATE_PIPE | UV_READABLE_PIPE | UV_WRITABLE_PIPE, .data.stream = (uv_stream_t*)stream}
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
    if (result) {
        fprintf(stderr, "Failed to spawn socat: %s\n", uv_strerror(result));
        free(process);
        uv_close((uv_handle_t*)stream, free_handle);
        return NULL;
    }

    return (uv_stream_t*)stream;
}

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal)
{
    free(process);
}
