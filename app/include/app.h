#ifndef APP_H
#define APP_H

#include <netdb.h>
#include <stdlib.h>
#include <stdbool.h>
#include <uv.h>
#include <lua.h>

#include "ircmsg.h"
#include "configuration.h"

struct app
{
    lua_State *L;
    struct configuration *cfg;
    uv_stream_t *console;
    uv_stream_t *irc;
    uv_loop_t loop;
    uv_poll_t input;
    uv_signal_t winch;
    uv_tcp_t *listeners;
    size_t listeners_len;
    bool closing;
};

struct app *app_new(struct configuration *cfg);
void app_free(struct app *a);
void app_set_irc(struct app *a, uv_stream_t *stream);
void app_clear_irc(struct app *a);
void app_set_window_size(struct app *a);
void do_command(struct app *a, char const* line, uv_stream_t *console);
void do_irc(struct app *a, struct ircmsg const*);
void do_keyboard(struct app *, long);
void do_mouse(struct app *, int x, int y);

static inline struct app **app_ref(lua_State *L)
{
    return lua_getextraspace(L);
}

#endif
