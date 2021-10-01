#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>

#include <uv.h>

#include "app.h"
#include "buffer.h"
#include "configuration.h"
#include "irc.h"
#include "read-line.h"
#include "write.h"
#include "socat.h"

struct close_state
{
    uv_loop_t *loop;
    struct configuration *cfg;
};

static void on_line(void *, char *msg);
static void on_connect(uv_connect_t* req, int status);
static void on_close(void *data);
static void on_reconnect(uv_timer_t *timer);
static void register_irc(uv_stream_t *irc, struct configuration *cfg);

int start_irc(uv_loop_t *loop, struct configuration *cfg)
{
    struct app * const a = loop->data;

    uv_stream_t *irc = socat_wrapper(loop, cfg->irc_socat);
    if (NULL == irc)
    {
        return 1;
    }
 
    struct readline_data *irc_data = malloc(sizeof *irc_data);
    assert(irc_data);

    struct close_state *close_data = malloc(sizeof *close_data);
    assert(close_data);

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

    register_irc(irc, cfg);

    app_set_irc(a, irc);

    int r = uv_read_start(irc, &my_alloc_cb, &readline_cb);
    assert(0 == r);

    return 0;
}

static void register_irc(uv_stream_t *irc, struct configuration *cfg)
{
    static char buffer[512];
    char const* msg;

    msg = "CAP REQ :znc.in/playback\r\n";
    to_write(irc, msg, strlen(msg));

    msg = "CAP END\r\n";
    to_write(irc, msg, strlen(msg));

    if (cfg->irc_pass)
    {
        snprintf(buffer, sizeof buffer, "PASS %s\r\n", cfg->irc_pass);
        to_write(irc, buffer, strlen(buffer));
    }

    snprintf(buffer, sizeof buffer, "NICK %s\r\n", cfg->irc_nick);
    to_write(irc, buffer, strlen(buffer));

    char const* irc_user = cfg->irc_user ? cfg->irc_user : cfg->irc_nick;
    char const* irc_gecos = cfg->irc_gecos ? cfg->irc_gecos : cfg->irc_nick;
    snprintf(buffer, sizeof buffer, "USER %s * * %s\r\n", irc_user, irc_gecos);
    to_write(irc, buffer, strlen(buffer));
}

static void on_close(void *data)
{
    struct close_state * const st = data;
    uv_loop_t * const loop = st->loop;
    struct app *a = loop->data;
    app_clear_irc(a);

    uv_timer_t *timer = malloc(sizeof *timer);
    uv_timer_init(loop, timer);
    timer->data = st;
    uv_timer_start(timer, on_reconnect, 5000, 0);
}

static void on_reconnect(uv_timer_t *timer)
{
    struct close_state * const st = timer->data;
    start_irc(st->loop, st->cfg);
    free(st);
    free(timer);
}

static void on_line(void *data, char *line)
{
    struct app *a = data;
    struct ircmsg irc;
    
    char *msg = strsep(&line, "\r\n");

    if (0 == parse_irc_message(msg, &irc))
    {
        do_irc(a, &irc);
    }
}
