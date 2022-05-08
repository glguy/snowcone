#include "socat.hpp"

#include "uv.hpp"

#include <cstdlib>
#include <iterator>
#include <iostream>
#include <memory>
#include <unistd.h>

std::optional<socat_pipes> socat_wrapper(uv_loop_t* loop, char const* socat)
{
    int r;
    char const* name = getenv("SOCAT");
    if (nullptr == name) { name = "socat"; }

    char const* argv[] = {name, "FD:3", socat, nullptr};

    auto irc_pipe = make_pipe(loop, 0);
    auto error_pipe = make_pipe(loop, 0);

    uv_stdio_container_t containers[] {
        {UV_IGNORE},
        {UV_IGNORE},
        {uv_stdio_flags(UV_CREATE_PIPE | UV_WRITABLE_PIPE),
         {stream_cast(error_pipe.get())}},
        {uv_stdio_flags(UV_CREATE_PIPE | UV_READABLE_PIPE | UV_WRITABLE_PIPE),
         {stream_cast(irc_pipe.get())}},
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
        delete process;
        std::cerr << "Failed to spawn socat: " << uv_strerror(r) << std::endl;
        return {};
    }

    return {{irc_pipe.release(), error_pipe.release()}};
}
