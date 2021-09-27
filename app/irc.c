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
#include "socat.h"

struct close_state
{
    uv_loop_t *loop;
    struct configuration *cfg;
};

static void on_line(void *, char *msg);
static void on_connect(uv_connect_t* req, int status);
static void on_close(void *data);

static void free_handle(uv_handle_t *handle)
{
    free(handle);
}

static uv_stream_t *make_connection(uv_loop_t *loop, struct configuration *cfg)
{
    uv_pipe_t *stream = malloc(sizeof *stream);
    uv_pipe_init(loop, stream, 0);

    int start_error = socat_wrapper(loop, cfg->irc_socat, (uv_stream_t*)stream);
    
    if (start_error) {
        fprintf(stderr, "Failed to spawn socat: %s\n", uv_strerror(start_error));
        uv_close((uv_handle_t*)stream, free_handle);
        return NULL;
    }

    return (uv_stream_t*)stream;
}

int start_irc(uv_loop_t *loop, struct configuration *cfg)
{
    struct app * const a = loop->data;

    uv_stream_t *irc = make_connection(loop, cfg);
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

    static char buffer[512];
    char const* msg;

    msg = "CAP REQ :znc.in/playback\r\n";
    to_write(irc, msg, strlen(msg));

    msg = "CAP END\r\n";
    to_write(irc, msg, strlen(msg));

    if (cfg->irc_pass)
    {
        snprintf(buffer, sizeof buffer, "PASS %s\r\n", cfg->irc_pass);
        buffer[sizeof buffer - 1] = '\0';
        to_write(irc, buffer, strlen(buffer));
    }

    snprintf(buffer, sizeof buffer, "NICK %s\r\n", cfg->irc_nick);
    buffer[sizeof buffer - 1] = '\0';
    to_write(irc, buffer, strlen(buffer));

    msg = "USER x * * x\r\n";
    to_write(irc, msg, strlen(msg));

    app_set_irc(a, irc, to_write);

    uv_read_start(irc, &my_alloc_cb, &readline_cb);

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
