#pragma once

#include <uv.h>

#include <chrono>
#include <concepts>
#include <exception>
#include <memory>

using namespace std::chrono_literals;
struct UV_error : public std::exception {
    uv_errno_t e;
    UV_error(uv_errno_t e) : e(e) {}
    char const* what() const noexcept override {
        return uv_err_name(e);
    }
};

inline auto uvok(int r) -> void {
    if (r != 0) { throw UV_error(uv_errno_t(r)); }
}

template<typename T, typename ... U>
concept IsAnyOf = (std::same_as<T, U> || ...);

template<typename T>
concept IsHandle = IsAnyOf<T
#define XX(_, name) , uv_##name##_t
UV_HANDLE_TYPE_MAP(XX)
#undef XX
>;

template<typename T>
requires IsHandle<T>
inline auto uv_close_xx(T* handle, uv_close_cb cb = nullptr) -> void {
    uv_close(reinterpret_cast<uv_handle_t*>(handle), cb);
}

template<typename T>
requires IsHandle<T>
inline auto uv_close_delete(T* handle) -> void {
    uv_close_xx(handle, [](auto handle) {
        delete reinterpret_cast<T*>(handle);
    });
}

template<IsHandle T>
struct HandleDeleter {
    inline void operator()(T* x) { uv_close_delete(x); }
};

template <IsHandle T>
using HandlePointer = std::unique_ptr<T, HandleDeleter<T>>;

HandlePointer<uv_tcp_t> make_tcp(uv_loop_t* loop);
HandlePointer<uv_pipe_t> make_pipe(uv_loop_t* loop, int ipc);
HandlePointer<uv_timer_t> make_timer(uv_loop_t* loop);

inline void uv_timer_start_xx(
    uv_timer_t *handle,
    std::chrono::milliseconds timeout,
    std::chrono::milliseconds repeat,
    uv_timer_cb cb)
{
    uvok(uv_timer_start(handle, cb, timeout.count(), repeat.count()));
}
