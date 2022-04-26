#pragma once

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