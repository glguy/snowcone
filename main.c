
#include "uv.h"
#include <uv.h>

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <libgen.h>

#include "app.h"
#include "buffer.h"

static void my_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
        buffer_init(buf, suggested_size);
}

struct readline_data
{
        void (*cb)(struct app *, char *);
        uv_buf_t buffer;
};

static void readline_data_close(struct readline_data *d)
{
        buffer_close(&d->buffer);
}

static void readline_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf)
{
        struct app *a = stream->loop->data;
        struct readline_data *d = stream->data;

        append_buffer(&d->buffer, nread, buf);

        char *start = d->buffer.base;
        char *end;

        while ((end = strchr(start, '\n')))
        {
                *end = '\0';
                d->cb(a, start);
                start = end + 1;
        }

        memmove(d->buffer.base, start, strlen(start) + 1);
}

static void on_file(uv_fs_event_t *handle, char const *filename, int events, int status)
{
        char const *target = handle->data;
        struct app *a = handle->loop->data;
        if (!strcmp(target, filename))
        {
                app_reload(a);
        }
}

int main(int argc, char **argv)
{
        if (argc < 3)
        {
                fprintf(stderr, "Bad arguments\n");
                return 1;
        }

        int fd = open(argv[2], O_RDONLY);
        if (-1 == fd)
        {
                perror("open");
                return 1;
        }

        uv_loop_t loop = {.data = app_new(argv[1])};
        uv_loop_init(&loop);

        struct readline_data stdin_data = {.cb = do_command};
        uv_pipe_t stdin_pipe = {.data = &stdin_data};
        uv_pipe_init(&loop, &stdin_pipe, 0);
        uv_pipe_open(&stdin_pipe, 0);
        uv_read_start((uv_stream_t *)&stdin_pipe, &my_alloc_cb, &readline_cb);

        struct readline_data snote_data = {.cb = do_snote};
        uv_pipe_t snote_pipe = {.data = &snote_data};
        uv_pipe_init(&loop, &snote_pipe, 0);
        uv_pipe_open(&snote_pipe, fd);
        uv_read_start((uv_stream_t *)&snote_pipe, &my_alloc_cb, &readline_cb);

        char *name = strdup(argv[1]);
        char *dir = strdup(argv[1]);
        uv_fs_event_t files = {.data = basename(name)};
        uv_fs_event_init(&loop, &files);
        uv_fs_event_start(&files, &on_file, dirname(dir), 0);
        free(dir);

        uv_run(&loop, UV_RUN_DEFAULT);

        uv_loop_close(&loop);
        readline_data_close(&stdin_data);
        readline_data_close(&snote_data);
        app_free(loop.data);

        return 0;
}
