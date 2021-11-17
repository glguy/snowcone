#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include <uv.h>

#include "app.h"
#include "configuration.h"
#include "irc.h"
#include "read-line.h"
#include "write.h"
#include "socat.h"

static void on_line(uv_stream_t *, char *msg);
static void on_err_line(uv_stream_t *stream, char *line);
static void on_connect(uv_connect_t* req, int status);
static void on_close(void *data);
static void on_reconnect(uv_timer_t *timer);

int start_irc(struct app *a)
{
    uv_stream_t *irc, *err;
    int r = socat_wrapper(&a->loop, a->cfg->irc_socat, &irc, &err);
    if (0 != r)
    {
        return 1;
    }
 
    struct readline_data *irc_data = calloc(1, sizeof *irc_data);
    assert(irc_data);
    irc_data->line_cb = on_line;
    irc->data = irc_data;
    app_set_irc(a, irc);
    r = uv_read_start(irc, readline_alloc, readline_cb);
    assert(0 == r);

    struct readline_data *err_data = calloc(1, sizeof *err_data);
    assert(err_data);
    err_data->line_cb = on_err_line;
    err->data = err_data;
    r = uv_read_start(err, readline_alloc, readline_cb);
    assert(0 == r);


    return 0;
}

static void on_err_line(uv_stream_t *stream, char *line)
{
    struct app * const a = stream->loop->data;

    if (line)
    {
        do_irc_err(a, line);
    }
}

static void on_line(uv_stream_t *stream, char *line)
{
    struct app * const a = stream->loop->data;
    int r;

    if (line)
    {
        struct ircmsg irc;
        char *msg = strsep(&line, "\r\n");

        if (0 == parse_irc_message(msg, &irc))
        {
            do_irc(a, &irc);
        }
    } else {
        app_clear_irc(a);

        if (!a->closing)
        {
            uv_timer_t *timer = malloc(sizeof *timer);
            assert(timer);

            r = uv_timer_init(&a->loop, timer);
            assert(0 == r);

            r = uv_timer_start(timer, on_reconnect, 5000, 0);
            assert(0 == r);
        }
    }
}

static void on_reconnect(uv_timer_t *timer)
{
    struct app * const a = timer->loop->data;
    free(timer);
    start_irc(a);
}
