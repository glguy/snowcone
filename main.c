#include <uv.h>

#include <libgen.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "app.h"
#include "buffer.h"

static const uint64_t timer_ms = 1000;

static void my_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf)
{
    buffer_init(buf, suggested_size);
}

/* INPUT LINE PROCESSING *********************************************/

struct readline_data
{
  uv_stream_t *write_data;
  void (*write_cb)(void *, char const *, size_t);
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
        *end++ = '\0';
        app_set_writer(a, d->write_data, d->write_cb);
        d->cb(a, start);
        app_set_writer(a, NULL, NULL);
        start = end;
    }

    memmove(d->buffer.base, start, strlen(start) + 1);
}

/* WRITE MESSAGE TO STREAM *******************************************/

static void write_done(uv_write_t *write, int status);

static void to_write(void *data, char const* msg, size_t n)
{
    uv_buf_t *buf = malloc(sizeof *buf);
    buffer_init(buf, n);
    memcpy(buf->base, msg, n);

    uv_write_t *req = malloc(sizeof *req);
    req->data = buf;

    uv_stream_t *stream = data;
    uv_write(req, stream, buf, 1, write_done);
}

static void write_done(uv_write_t *write, int status)
{
    uv_buf_t *buf = write->data;
    buffer_close(buf);
    free(buf);
    free(write);
}

/* TCP SERVER ********************************************************/

static void on_new_connection(uv_stream_t *server, int status);

static void start_tcp_server(uv_loop_t *loop, char const* host, int port)
{
    struct sockaddr_in6 addr;
    uv_ip6_addr(host, port, &addr);

    uv_tcp_t *tcp = malloc(sizeof *tcp);
    uv_tcp_init(loop, tcp);
    uv_tcp_bind(tcp, (struct sockaddr*)&addr, 0);
    uv_listen((uv_stream_t*)tcp, SOMAXCONN, &on_new_connection);
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
    uv_accept(server, (uv_stream_t*)client);
    data->write_data = (uv_stream_t *)client;
    data->write_cb = to_write;
    uv_read_start((uv_stream_t *)client, my_alloc_cb, readline_cb);
}

/* TIMER *************************************************************/

static void on_timer(uv_timer_t *handle);

static void start_timer(uv_loop_t *loop, uv_stream_t *output)
{
    uv_timer_t *timer = malloc(sizeof *timer);
    timer->data = output;
    uv_timer_init(loop, timer);
    uv_timer_start(timer, on_timer, timer_ms, timer_ms);
}

static void on_timer(uv_timer_t *timer)
{
    struct app *a = timer->loop->data;
    uv_stream_t *output = timer->data;
    app_set_writer(a, output, to_write);
    do_timer(a);
    app_set_writer(a, NULL, NULL);
}

/* FILE WATCHER ******************************************************/

struct file_watcher_data {
    char *name;
    uv_stream_t *output;
};

static void on_file(uv_fs_event_t *handle, char const *filename, int events, int status);

static void start_file_watcher(uv_loop_t *loop, uv_stream_t *stream, char const* logic_name)
{
    uv_fs_event_t *files = malloc(sizeof *files);
    struct file_watcher_data *data = malloc(sizeof *data);
    files->data = data;
    data->output = stream;
    char *temp = strdup(logic_name);
    data->name = strdup(basename(temp));
    free(temp);

    uv_fs_event_init(loop, files);
    
    temp = strdup(logic_name);
    uv_fs_event_start(files, &on_file, dirname(temp), 0);
    free(temp);
}

static void on_file(uv_fs_event_t *handle, char const *filename, int events, int status)
{
    struct file_watcher_data *data = handle->data;
    struct app *a = handle->loop->data;
    if (!strcmp(data->name, filename))
    {
        app_set_writer(a, data->output, to_write);
        app_reload(a);
        app_set_writer(a, NULL, NULL);
    }
}

/* MAIN **************************************************************/

void update_tty_size(struct app *a, uv_tty_t *tty)
{
    int width, height;
    uv_tty_get_winsize(tty, &width, &height);
    app_set_window_size(a, width, height);
}

void on_winch(uv_signal_t* handle, int signum)
{
    uv_tty_t *tty = handle->data;
    struct app *a = handle->loop->data;
    update_tty_size(a, tty);
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

    char const* const logic_name = argv[0];
    char const* const snote_name = argv[1];

    struct app *a = app_new(logic_name);
    uv_loop_t loop = {.data = a};
    uv_loop_init(&loop);

    uv_fs_t req;
    uv_file fd = uv_fs_open(&loop, &req, snote_name, UV_FS_O_RDONLY, 0660, NULL);
    uv_fs_req_cleanup(&req);
    if (fd < 0)
    {
        fprintf(stderr, "open: %s\n", uv_err_name(fd));
        return 1;
    }

    uv_tty_t stdout_tty;
    uv_tty_init(&loop, &stdout_tty, STDOUT_FILENO, /*unused*/0);
    update_tty_size(a, &stdout_tty);

    uv_signal_t winch = {.data = &stdout_tty};
    uv_signal_init(&loop, &winch);
    uv_signal_start(&winch, on_winch, SIGWINCH);
    
    struct readline_data stdin_data = {
        .cb = do_command,
        .write_cb = &to_write,
        .write_data = (uv_stream_t*)&stdout_tty,
    };
    uv_tty_t stdin_tty = {.data = &stdin_data};
    uv_tty_init(&loop, &stdin_tty, STDIN_FILENO, /*unused*/0);
    uv_read_start((uv_stream_t *)&stdin_tty, &my_alloc_cb, &readline_cb);

    struct readline_data snote_data = {
        .cb = do_snote,
        .write_data = (uv_stream_t*)&stdout_tty,
        .write_cb = &to_write,
    };
    uv_pipe_t snote_pipe = {.data = &snote_data};
    uv_pipe_init(&loop, &snote_pipe, 0);
    uv_pipe_open(&snote_pipe, fd);
    uv_read_start((uv_stream_t *)&snote_pipe, &my_alloc_cb, &readline_cb);

    start_file_watcher(&loop, (uv_stream_t*)&stdout_tty, logic_name);

    if (port > 0)
    {
        start_tcp_server(&loop, bindaddr, port);
    }

    start_timer(&loop, (uv_stream_t*)&stdout_tty);
    
    uv_run(&loop, UV_RUN_DEFAULT);

    uv_loop_close(&loop);
    app_free(loop.data);

    return 0;
}
