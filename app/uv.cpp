#include "uv.hpp"

HandlePointer<uv_tcp_t> make_tcp(uv_loop_t* loop) {
    auto tcp = std::make_unique<uv_tcp_t>();
    uvok(uv_tcp_init(loop, tcp.get()));
    return HandlePointer<uv_tcp_t>(tcp.release());
}

HandlePointer<uv_timer_t> make_timer(uv_loop_t* loop) {
    auto timer = std::make_unique<uv_timer_t>();
    uvok(uv_timer_init(loop, timer.get()));
    return HandlePointer<uv_timer_t>(timer.release());
}

HandlePointer<uv_pipe_t> make_pipe(uv_loop_t* loop, int ipc) {
    auto pipe = std::make_unique<uv_pipe_t>();
    uvok(uv_pipe_init(loop, pipe.get(), ipc));
    return HandlePointer<uv_pipe_t>(pipe.release());
}