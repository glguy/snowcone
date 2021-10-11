#include <assert.h>
#include <stdlib.h>
#include <string.h>

#include <uv.h>

#include "app.h"
#include "buffer.h"
#include "configuration.h"
#include "irc.h"
#include "read-line.h"
#include "write.h"
#include "socat.h"

static void on_line(void *, char *msg);
static void on_connect(uv_connect_t* req, int status);
static void on_close(void *data);
static void on_reconnect(uv_timer_t *timer);

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

    *irc_data = (struct readline_data) {
        .read = on_line,
        .read_data = a,
    };
    irc->data = irc_data;

    app_set_irc(a, irc);

    int r = uv_read_start(irc, &my_alloc_cb, &readline_cb);
    assert(0 == r);

    return 0;
}

static void on_line(void *data, char *line)
{
    struct app * const a = data;
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
        uv_loop_t * const loop = a->loop;
        app_clear_irc(a);

        uv_timer_t *timer = malloc(sizeof *timer);
        assert(timer);

        r = uv_timer_init(loop, timer);
        assert(0 == r);

        r = uv_timer_start(timer, on_reconnect, 5000, 0);
        assert(0 == r);
    }
}

static void on_reconnect(uv_timer_t *timer)
{
    struct app * const a = timer->loop->data;
    free(timer);
    start_irc(a->loop, a->cfg);    
}
