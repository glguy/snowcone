#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "socat.hpp"

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal);

int socat_wrapper(uv_loop_t *loop, char const* socat, uv_stream_t **irc_stream, uv_stream_t **error_stream)
{
    int r;
    char const* argv[] = {"socat", "FD:3", socat, nullptr};

    auto irc_pipe = new uv_pipe_t;
    assert(irc_pipe);
    r = uv_pipe_init(loop, irc_pipe, 0);
    assert(0 == r);

    auto error_pipe = new uv_pipe_t;
    r = uv_pipe_init(loop, error_pipe, 0);
    assert(0 == r);

    uv_stdio_container_t containers[] = {
        {.flags = UV_IGNORE},
        {.flags = UV_IGNORE},
        {.flags = uv_stdio_flags(UV_CREATE_PIPE | UV_WRITABLE_PIPE), .data.stream = (uv_stream_t*)error_pipe},
        {.flags = uv_stdio_flags(UV_CREATE_PIPE | UV_READABLE_PIPE | UV_WRITABLE_PIPE), .data.stream = (uv_stream_t*)irc_pipe}
    };

    uv_process_options_t options {};
    options.file = "socat";
    options.args = const_cast<char**>(argv); // libuv doesn't actually write to these
    options.exit_cb = socat_exit;
    options.stdio_count = sizeof containers / sizeof *containers;
    options.stdio = containers;

    auto process = new uv_process_t;
    r = uv_spawn(loop, process, &options);
    if (0 != r) {
        fprintf(stderr, "Failed to spawn socat: %s\n", uv_strerror(r));
        delete process;
        uv_close(reinterpret_cast<uv_handle_t*>(irc_stream), [](auto h) { delete h; });
        uv_close(reinterpret_cast<uv_handle_t*>(error_stream), [](auto h) { delete h; });
        return 1;
    }

    *irc_stream = (uv_stream_t*)irc_pipe;
    *error_stream = (uv_stream_t*)error_pipe;
    return 0;
}

static void socat_exit(uv_process_t *process, int64_t exit_status, int term_signal)
{
    delete process;
}
