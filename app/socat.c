#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "socat.h"

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal);
static void free_handle(uv_handle_t *handle);

int socat_wrapper(uv_loop_t *loop, char const* socat, uv_stream_t **irc_stream, uv_stream_t **error_stream)
{
    int r;
    char const* argv[] = {"socat", "FD:3", socat, NULL};

    uv_pipe_t *irc_pipe = malloc(sizeof *irc_pipe);
    assert(irc_pipe);
    r = uv_pipe_init(loop, irc_pipe, 0);
    assert(0 == r);

    uv_pipe_t *error_pipe = malloc(sizeof *irc_pipe);
    assert(error_pipe);
    r = uv_pipe_init(loop, error_pipe, 0);
    assert(0 == r);

    uv_stdio_container_t containers[] = {
        {.flags = UV_IGNORE},
        {.flags = UV_IGNORE},
        {.flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE, .data.stream = (uv_stream_t*)error_pipe},
        {.flags = UV_CREATE_PIPE | UV_READABLE_PIPE | UV_WRITABLE_PIPE, .data.stream = (uv_stream_t*)irc_pipe}
    };

    uv_process_options_t options = {
        .file = "socat",
        .args = (char**)argv, // libuv doesn't actually write to these
        .exit_cb = socat_exit,
        .stdio_count = sizeof containers / sizeof *containers,
        .stdio = containers,
    };

    uv_process_t *process = malloc(sizeof *process);
    assert(process);

    r = uv_spawn(loop, process, &options);
    if (0 != r) {
        fprintf(stderr, "Failed to spawn socat: %s\n", uv_strerror(r));
        free(process);
        uv_close((uv_handle_t*)irc_stream, free_handle);
        uv_close((uv_handle_t*)error_stream, free_handle);
        return 1;
    }

    *irc_stream = (uv_stream_t*)irc_pipe;
    *error_stream = (uv_stream_t*)error_pipe;
    return 0;
}

static void free_handle(uv_handle_t *handle)
{
    free(handle);
}

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal)
{
    free(process);
}
