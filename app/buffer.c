#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include "buffer.h"

void buffer_close(uv_buf_t const *buf)
{
    free(buf->base);
}

void buffer_init(uv_buf_t *buf, size_t n)
{
    char *p = calloc(n,1);
    assert(p);
    *buf = uv_buf_init(p, n);
}

void append_buffer(uv_buf_t *dst, size_t n, uv_buf_t const *src)
{
    if (dst->base == NULL)
    {
        buffer_init(dst, 512);
    }

    if (!src->base)
        return;

    size_t dlen = strlen(dst->base);
    size_t len = dlen + n;

    if (len >= dst->len)
    {
        while (len >= dst->len)
        {
            dst->len *= 2;
        }
        dst->base = realloc(dst->base, dst->len);
        assert(dst->base);
    }

    memcpy(dst->base + dlen, src->base, n);
    dst->base[len] = '\0';

    buffer_close(src);
}

void my_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
    buffer_init(buf, suggested_size);
}
