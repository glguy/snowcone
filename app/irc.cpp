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

int start_irc(struct app *a)
{
    uv_pipe_t *irc, *err;
    int r = socat_wrapper(&a->loop, a->cfg->irc_socat, &irc, &err);
    if (0 != r)
    {
        return 1;
    }

    a->set_irc(reinterpret_cast<uv_stream_t*>(irc));
    readline_start(irc, on_line);
    readline_start(err, on_err_line);

    return 0;
}

static void on_err_line(uv_stream_t *stream, char *line)
{
    auto const a = static_cast<app*>(stream->loop->data);

    if (line)
    {
        a->do_irc_err(line);
    }
}

static void on_line(uv_stream_t *stream, char *line)
{
    auto const a = static_cast<app*>(stream->loop->data);

    if (line)
    {
        struct ircmsg irc;
        char *msg = strsep(&line, "\r\n");

        if (0 == parse_irc_message(msg, &irc))
        {
            a->do_irc(&irc);
        }
    } else {
        a->clear_irc();

        if (!a->closing)
        {
            auto timer = new uv_timer_t;
            uvok(uv_timer_init(&a->loop, timer));
            uvok(uv_timer_start(timer, [](auto timer) {
                auto const a = static_cast<app*>(timer->loop->data);
                uv_close_delete(timer);
                start_irc(a);
            }, 5000, 0));
        }
    }
}
