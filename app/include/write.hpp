#pragma once

#include <uv.h>

#include <cstdlib>

void to_write(uv_stream_t* data, char const* msg, size_t n);
