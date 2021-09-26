#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <uv.h>
#include <uv/unix.h>

#include "app.h"
#include "buffer.h"
#include "configuration.h"
#include "irc.h"
#include "read-line.h"
#include "write.h"
#include "tls-helper.h"

struct close_state
{
    uv_loop_t *loop;
    struct configuration *cfg;
};

static void on_line(void *, char *msg);
static void on_connect(uv_connect_t* req, int status);
static void on_close(void *data);

static uv_tcp_t *make_connection(uv_loop_t *loop, struct configuration *cfg)
{
    uv_os_sock_t fds[2];

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds))
    {
        perror("socketpair");
        return NULL;
    }

    int oldflags = fcntl(fds[0], F_GETFD);
    if (oldflags < 0)
    {
        perror("fcntl");
        close(fds[0]);
        close(fds[1]);
        return NULL;
    }

    int res = fcntl(fds[0], F_SETFD, FD_CLOEXEC | oldflags);
    if (res < 0)
    {
        perror("fcntl");
        close(fds[0]);
        close(fds[1]);
        return NULL;
    }

    int start_error = tls_wrapper(loop, cfg->irc_socat, fds[1]);
    close(fds[1]);

    if (start_error) {
        fprintf(stderr, "Failed to spawn socat: %s\n", uv_strerror(start_error));
        close(fds[0]);
        return NULL;
    }

    uv_tcp_t *tcp = malloc(sizeof *tcp);
    uv_tcp_init(loop, tcp);
    uv_tcp_open(tcp, fds[0]);

    return tcp;
}

int start_irc(uv_loop_t *loop, struct configuration *cfg)
{
    struct app * const a = loop->data;

    uv_tcp_t *irc = make_connection(loop, cfg);
    if (NULL == irc)
    {
        return 1;
    }
 
    struct readline_data *irc_data = malloc(sizeof *irc_data);
    struct close_state *close_data = malloc(sizeof *close_data);
    *irc_data = (struct readline_data) {
        .read = on_line,
        .read_data = a,
        .close = on_close,
        .close_data = close_data,
    };
    irc->data = irc_data;
    *close_data = (struct close_state) {
        .loop = loop,
        .cfg = cfg,
    };

    uv_stream_t *stream = (uv_stream_t*)irc;

    static char buffer[512];
    char const* msg;

    msg = "CAP REQ :znc.in/playback\r\n";
    to_write(stream, msg, strlen(msg));

    msg = "CAP END\r\n";
    to_write(stream, msg, strlen(msg));

    if (cfg->irc_pass)
    {
        snprintf(buffer, sizeof buffer, "PASS %s\r\n", cfg->irc_pass);
        buffer[sizeof buffer - 1] = '\0';
        to_write(stream, buffer, strlen(buffer));
    }

    snprintf(buffer, sizeof buffer, "NICK %s\r\n", cfg->irc_nick);
    buffer[sizeof buffer - 1] = '\0';
    to_write(stream, buffer, strlen(buffer));

    msg = "USER x * * x\r\n";
    to_write(stream, msg, strlen(msg));

    app_set_irc(a, stream, to_write);

    uv_read_start(stream, &my_alloc_cb, &readline_cb);

    return 0;
}

static void on_close(void *data)
{
    struct close_state * const st = data;
    uv_loop_t * const loop = st->loop;
    struct app *a = loop->data;
    app_clear_irc(a);
    start_irc(loop, st->cfg);
    free(st);
}

static void on_line(void *data, char *line)
{
    struct app *a = data;
    struct ircmsg irc;
    
    char *msg = strsep(&line, "\r");

    if (0 == parse_irc_message(&irc, msg))
    {
        do_irc(a, &irc);
    }
}
