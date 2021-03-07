#include <sys/socket.h>
#define _XOPEN_SOURCE 600

#include <uv.h>

#include <libgen.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <netdb.h>

#include <curses.h>
#include <locale.h>

#include "app.h"
#include "buffer.h"

static const uint64_t timer_ms = 1000;
static const uint64_t mrs_update_ms = 30 * 1000;

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

static void start_tcp_server(uv_loop_t *loop, char const* node, char const* service)
{
    struct addrinfo hints = {
        .ai_flags = AI_PASSIVE,
        .ai_family = PF_UNSPEC,
        .ai_socktype = SOCK_STREAM,
    };
    uv_getaddrinfo_t req;
    int res = uv_getaddrinfo(loop, &req, NULL, node, service, &hints);
    if (res < 0)
    {
        fprintf(stderr, "failed to resolve tcp bind: %s\n", uv_err_name(res));
        exit(1);
    }
    
    for (struct addrinfo *ai = req.addrinfo; ai; ai = ai->ai_next)
    {
        uv_tcp_t *tcp = malloc(sizeof *tcp);
        uv_tcp_init(loop, tcp);
        uv_tcp_bind(tcp, ai->ai_addr, 0);
        uv_listen((uv_stream_t*)tcp, SOMAXCONN, &on_new_connection);
    }
    uv_freeaddrinfo(req.addrinfo);
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

static void start_timer(uv_loop_t *loop)
{
    uv_timer_t *timer = malloc(sizeof *timer);
    uv_timer_init(loop, timer);
    uv_timer_start(timer, on_timer, timer_ms, timer_ms);
}

static void on_timer(uv_timer_t *timer)
{
    struct app *a = timer->loop->data;
    do_timer(a);
}

/* FILE WATCHER ******************************************************/

struct file_watcher_data {
    char *name;
};

static void on_file(uv_fs_event_t *handle, char const *filename, int events, int status);

static void start_file_watcher(uv_loop_t *loop, char const* logic_name)
{
    uv_fs_event_t *files = malloc(sizeof *files);
    struct file_watcher_data *data = malloc(sizeof *data);
    files->data = data;
    char *temp = strdup(logic_name);
    *data = (struct file_watcher_data) {
        .name = strdup(basename(temp)),
    };
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
        app_reload(a);
    }
}

/* Main Input ********************************************************/

static void on_stdin(uv_poll_t *handle, int status, int events)
{
    struct app *a = handle->loop->data;

    wint_t key;
    while(ERR != get_wch(&key))
    {
        do_keyboard(a, key);
    }
}

/* MRS LOOKUP ********************************************************/

static void on_mrs_timer(uv_timer_t *timer);
static void on_mrs_getaddrinfo(uv_getaddrinfo_t *, int, struct addrinfo *);

static void start_mrs_timer(uv_loop_t *loop)
{
    uv_timer_t *timer = malloc(sizeof *timer);
    uv_timer_init(loop, timer);
    uv_timer_start(timer, on_mrs_timer, 0, mrs_update_ms);
}

static void on_mrs_timer(uv_timer_t *timer)
{
    static struct addrinfo const hints = {
        .ai_socktype = SOCK_STREAM,
    };
    static struct addrinfo const hints4 = {
        .ai_family = PF_INET,
        .ai_socktype = SOCK_STREAM,
    };
    static struct addrinfo const hints6 = {
        .ai_family = PF_INET6,
        .ai_socktype = SOCK_STREAM,
    };

    uv_getaddrinfo_t *req;
    uv_loop_t *loop = timer->loop;

    req = malloc(sizeof *req); req->data = "";
    uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, "chat.freenode.net", NULL, &hints);

    req = malloc(sizeof *req); req->data = "US";
    uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, "chat.us.freenode.net", NULL, &hints);

    req = malloc(sizeof *req); req->data = "EU";
    uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, "chat.eu.freenode.net", NULL, &hints);

    req = malloc(sizeof *req); req->data = "AU";
    uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, "chat.au.freenode.net", NULL, &hints);

    req = malloc(sizeof *req); req->data = "IPV4";
    uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, "chat.ipv4.freenode.net", NULL, &hints4);

    req = malloc(sizeof *req); req->data = "IPV6";
    uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, "chat.ipv6.freenode.net", NULL, &hints6);
}

static void on_mrs_getaddrinfo(uv_getaddrinfo_t *req, int status, struct addrinfo *ai)
{
    char const* const name = req->data;

    if (0 == status)
    {
        do_mrs(req->loop->data, name, ai);
        uv_freeaddrinfo(ai);
    }
    free(req);
}

/* MAIN **************************************************************/

void on_winch(uv_signal_t* handle, int signum)
{
    struct app *a = handle->loop->data;
    endwin();
    refresh();
    app_set_window_size(a);
}

int main(int argc, char *argv[])
{
    char const* const program = argv[0];

    char const* host = NULL;
    char const* port = NULL;

    int opt;
    while ((opt = getopt(argc, argv, "h:p:")) != -1) {
        switch (opt) {
        case 'h':
            host = optarg;
            break;
        case 'p':
            port = optarg;
            break;
        default:
            fprintf(stderr, "Usage: %s [-h host] [-p port] logic.lua snote_pipe\n", program);
            return 1;
        }
    }

    argv += optind;
    argc -= optind;

    if (argc < 2)
    {
        fprintf(stderr, "Usage: %s [-h host] [-p port] logic.lua snote_pipe\n", program);
        return 1;
    }

    /* Configure ncurses */
    setlocale(LC_ALL, "");
    initscr(); 
    start_color();
    use_default_colors();
    timeout(0);
    cbreak();
    noecho();
    nonl();
    intrflush(stdscr, FALSE);
    keypad(stdscr, TRUE);
    curs_set(0);

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

    uv_poll_t input;
    uv_poll_init(&loop, &input, STDIN_FILENO);
    uv_poll_start(&input, UV_READABLE, on_stdin);

    uv_signal_t winch;
    uv_signal_init(&loop, &winch);
    uv_signal_start(&winch, on_winch, SIGWINCH);

    struct readline_data snote_data = {
        .cb = do_snote,
    };
    uv_pipe_t snote_pipe = {.data = &snote_data};
    uv_pipe_init(&loop, &snote_pipe, 0);
    uv_pipe_open(&snote_pipe, fd);
    uv_read_start((uv_stream_t *)&snote_pipe, &my_alloc_cb, &readline_cb);

    start_file_watcher(&loop, logic_name);

    if (port != 0)
    {
        start_tcp_server(&loop, host, port);
    }

    start_timer(&loop);
    start_mrs_timer(&loop);

    uv_run(&loop, UV_RUN_DEFAULT);

    endwin();

    uv_loop_close(&loop);
    app_free(loop.data);

    return 0;
}
