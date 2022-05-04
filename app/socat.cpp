#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <cstdlib>

#include "socat.hpp"
#include "uv.hpp"

std::optional<socat_pipes> socat_wrapper(uv_loop_t* loop, char const* socat)
{
    int r;
    char const* argv[] = {"socat", "FD:3", socat, nullptr};

    auto irc_pipe = static_cast<uv_pipe_t*>(calloc(1, sizeof (uv_pipe_t)));
    uvok(uv_pipe_init(loop, irc_pipe, 0));

    auto error_pipe = static_cast<uv_pipe_t*>(calloc(1, sizeof (uv_pipe_t)));
    uvok(uv_pipe_init(loop, error_pipe, 0));

    uv_stdio_container_t containers[] {
        {},
        {},
        {uv_stdio_flags(UV_CREATE_PIPE | UV_WRITABLE_PIPE),
         {reinterpret_cast<uv_stream_t*>(error_pipe)}},
        {uv_stdio_flags(UV_CREATE_PIPE | UV_READABLE_PIPE | UV_WRITABLE_PIPE),
         {reinterpret_cast<uv_stream_t*>(irc_pipe)}},
    };

    uv_process_options_t options {};
    options.file = "socat";
    options.args = const_cast<char**>(argv); // libuv doesn't actually write to these
    options.exit_cb = [](auto process, auto status, auto signal){
        uv_close_delete(process);
    };
    options.stdio_count = sizeof containers / sizeof *containers;
    options.stdio = containers;

    auto process = new uv_process_t;
    r = uv_spawn(loop, process, &options);
    if (0 != r) {
        fprintf(stderr, "Failed to spawn socat: %s\n", uv_strerror(r));
        delete process;
        uv_close_delete(irc_pipe);
        uv_close_delete(error_pipe);
        return {};
    }

    return {{irc_pipe, error_pipe}};
}
