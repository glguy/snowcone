#pragma once

#include <concepts>
#include <exception>

#include <uv.h>

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
auto uv_close_xx(T* handle, uv_close_cb cb = nullptr) {
    uv_close(reinterpret_cast<uv_handle_t*>(handle), cb);
}
