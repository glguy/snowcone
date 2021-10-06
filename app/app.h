#ifndef APP_H
#define APP_H

#include <netdb.h>
#include <stdlib.h>
#include <uv.h>

#include "ircmsg.h"
#include "configuration.h"

struct app;

struct app *app_new(uv_loop_t *loop, struct configuration *cfg);
void app_free(struct app *a);
void app_reload(struct app *a);
void app_set_irc(struct app *a, uv_stream_t *stream);
void app_clear_irc(struct app *a);
void app_set_window_size(struct app *a);
void do_command(struct app *a, char const* line, uv_stream_t *console);
void do_irc(struct app *a, struct ircmsg const*);
void do_timer(struct app *a);
void do_keyboard(struct app *, long);
void do_mrs(struct app *, char const* host, struct addrinfo const* ai);
void do_mouse(struct app *, int x, int y);
#endif
