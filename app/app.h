#ifndef APP_H
#define APP_H

#include <netdb.h>
#include <stdlib.h>

#include "ircmsg.h"

struct app;

struct app *app_new(char const *logic);
void app_free(struct app *a);
void app_reload(struct app *a);
void app_set_irc(struct app *a, void *data, void (*cb)(void*, char const*, size_t));
void app_clear_irc(struct app *a);
void app_set_window_size(struct app *a);
void do_command(struct app *a, char const* line, void *data, void (*cb)(void*, char const*, size_t));
void do_irc(struct app *a, struct ircmsg const*);
void do_timer(struct app *a);
void do_keyboard(struct app *, long);
void do_mrs(struct app *, char const* host, struct addrinfo const* ai);
void do_mouse(struct app *, int x, int y);
#endif
