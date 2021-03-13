#include <string.h>

#include "app.h"
#include "irc.h"
#include "write.h"
#include "read-line.h"
#include "buffer.h"

static void on_line(void *, char *msg);

static void on_connect(uv_connect_t* req, int status)
{
    struct configuration *cfg = req->data;
    uv_stream_t *stream = req->handle;
    uv_loop_t *loop = stream->loop;
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

    free(req);
}

void start_irc(uv_loop_t *loop, struct configuration *cfg)
{
    struct readline_data *irc_data = malloc(sizeof *irc_data);
    *irc_data = (struct readline_data) {
        .cb = on_line,
        .cb_data = loop->data,
    };
    
    uv_tcp_t *irc = malloc(sizeof *irc);
    irc->data = irc_data;
    uv_tcp_init(loop, irc);

    struct sockaddr_in addr;
    uv_ip4_addr(cfg->irc_node, atoi(cfg->irc_service), &addr);

    uv_connect_t *req = malloc(sizeof *req);
    req->data = cfg;
    int res = uv_tcp_connect(req, irc, (struct sockaddr*)&addr, &on_connect);
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
