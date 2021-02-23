
#include "uv.h"
#include <bits/getopt_core.h>
#include <uv.h>

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <libgen.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <unistd.h>

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
        bool dynamic;
};

static void readline_data_close(struct readline_data *d)
{
        buffer_close(&d->buffer);
        if (d->dynamic)
        {
                free(d);
        }
}

static void readline_close_cb(uv_handle_t *handle)
{
        struct readline_data *d = handle->data;
        bool dynamic = d->dynamic;
        readline_data_close(handle->data);
        if (dynamic)
        {
                free(handle);
        }
}

static void readline_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf)
{
        struct app * const a = stream->loop->data;
        struct readline_data * const d = stream->data;

        if (nread < 0)
        {
                buffer_close(buf);
                uv_close((uv_handle_t *)stream, readline_close_cb);
                return;
        }

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

static void on_new_connection(uv_stream_t *server, int status)
{
        if (status < 0) {
                fprintf(stderr, "New connection error %s\n", uv_strerror(status));
                return;
        }

        struct readline_data *data = malloc(sizeof *data);
        data->cb = &do_command;
        data->dynamic = true;
        buffer_init(&data->buffer, 512);

        uv_tcp_t *client = malloc(sizeof *client);
        client->data = data;
        uv_tcp_init(server->loop, client);
        if (uv_accept(server, (uv_stream_t*) client) == 0) {
                uv_read_start((uv_stream_t*) client, my_alloc_cb, readline_cb);
        }
        else
        {
                uv_close((uv_handle_t*)client, NULL);
        }
}



int main(int argc, char *argv[])
{
        char const* const program = argv[0];

        int port = 0;
        char const* bindaddr = "::";

        int opt;
        while ((opt = getopt(argc, argv, "h:p:")) != -1) {
                switch (opt) {
                case 'h':
                        bindaddr = optarg;
                        break;
                case 'p':
                        port = atoi(optarg);
                        break;
                default:
                        fprintf(stderr, "Usage: %s [-p port] logic.lua snote_pipe\n", program);
                        return 1;
                }
        }

        argv += optind;
        argc -= optind;

        if (argc < 2)
        {
                fprintf(stderr, "Usage: %s [-p port] logic.lua snote_pipe\n", program);
                return 1;
        }

        int fd = open(argv[1], O_RDONLY);
        if (-1 == fd)
        {
                perror("open");
                return 1;
        }

        uv_loop_t loop = {.data = app_new(argv[0])};
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

        char *name = strdup(argv[0]);
        char *dir = strdup(argv[0]);
        uv_fs_event_t files = {.data = basename(name)};
        uv_fs_event_init(&loop, &files);
        uv_fs_event_start(&files, &on_file, dirname(dir), 0);
        free(dir);

        uv_tcp_t tcp;
        if (port > 0) 
        {
                struct sockaddr_in6 addr;
                uv_ip6_addr(bindaddr, port, &addr);
                uv_tcp_init(&loop, &tcp);
                uv_tcp_bind(&tcp, (struct sockaddr const*)&addr, 0);
                uv_listen((uv_stream_t*)&tcp, 3, &on_new_connection);
        }

        uv_run(&loop, UV_RUN_DEFAULT);

        uv_loop_close(&loop);
        readline_data_close(&stdin_data);
        readline_data_close(&snote_data);
        app_free(loop.data);

        return 0;
}
