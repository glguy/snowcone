#include "socat.hpp"

#include "uv.hpp"

#include <cstdlib>
#include <iterator>
#include <iostream>
#include <unistd.h>

std::optional<socat_pipes> socat_wrapper(uv_loop_t* loop, char const* socat)
{
    int r;
    char const* name = getenv("SOCAT");
    if (nullptr == name) { name = "socat"; }

    char const* argv[] = {name, "FD:3", socat, nullptr};

    auto irc_pipe = new uv_pipe_t;
    uvok(uv_pipe_init(loop, irc_pipe, 0));

    auto error_pipe = new uv_pipe_t;
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
    options.file = name;
    options.args = const_cast<char**>(argv); // libuv doesn't actually write to these
    options.exit_cb = [](auto process, auto status, auto signal){
        uv_close_delete(process);
    };
    options.stdio_count = std::size(containers);
    options.stdio = containers;

    auto process = new uv_process_t;
    r = uv_spawn(loop, process, &options);
    if (0 != r) {
        std::cerr << "Failed to spawn socat: " << uv_strerror(r) << std::endl;
        uv_close_delete(process);
        uv_close_delete(irc_pipe);
        uv_close_delete(error_pipe);
        return {};
    }

    return {{irc_pipe, error_pipe}};
}
