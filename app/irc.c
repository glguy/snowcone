#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <uv.h>
#include <uv/unix.h>

#include "app.h"
#include "buffer.h"
#include "irc.h"
#include "read-line.h"
#include "write.h"
#include "tls-helper.h"

static void on_line(void *, char *msg);
static void on_connect(uv_connect_t* req, int status);

static uv_tcp_t *make_connection(uv_loop_t *loop, struct configuration *cfg)
{
    uv_os_sock_t fds[2];

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds))
    {
        perror("socketpair");
        exit(EXIT_FAILURE);
    }

    int oldflags = fcntl(fds[0], F_GETFD);
    if (oldflags < 0)
    {
        perror("fcntl");
        exit(EXIT_FAILURE);
    }

    int res = fcntl(fds[0], F_SETFD, FD_CLOEXEC | oldflags);
    if (res < 0)
    {
        perror("fcntl");
        exit(EXIT_FAILURE);
    }

    tls_wrapper(loop, cfg->irc_socat, fds[1]);
    close(fds[1]);

    uv_tcp_t *tcp = malloc(sizeof *tcp);
    uv_tcp_init(loop, tcp);
    uv_tcp_open(tcp, fds[0]);

    return tcp;
}

void start_irc(uv_loop_t *loop, struct configuration *cfg)
{
    struct readline_data *irc_data = malloc(sizeof *irc_data);
    *irc_data = (struct readline_data) {
        .cb = on_line,
        .cb_data = loop->data,
    };

    uv_tcp_t *irc = make_connection(loop, cfg);
    irc->data = irc_data;

    uv_stream_t *stream = (uv_stream_t*)irc;
    struct app *a = loop->data;

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
