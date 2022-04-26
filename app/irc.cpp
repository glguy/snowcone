#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include <uv.h>

#include "app.hpp"
#include "configuration.hpp"
#include "irc.hpp"
#include "read-line.hpp"
#include "socat.hpp"
#include "write.hpp"

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

    app_set_irc(a, irc);
    r = readline_start(irc, on_line);
    assert(0 == r);

    r = readline_start(err, on_err_line);
    assert(0 == r);


    return 0;
}

static void on_err_line(uv_stream_t *stream, char *line)
{
    auto const a = static_cast<app*>(stream->loop->data);

    if (line)
    {
        do_irc_err(a, line);
    }
}

static void on_line(uv_stream_t *stream, char *line)
{
    auto const a = static_cast<app*>(stream->loop->data);
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
            auto timer = new uv_timer_t;
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
    auto  const a = static_cast<app*>(timer->loop->data);
    delete timer;
    start_irc(a);
}
