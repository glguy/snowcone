#ifndef APP_H
#define APP_H

#include <netdb.h>
#include <stdlib.h>

struct app;

struct app *app_new(char const *logic);
void app_free(struct app *a);
void app_reload(struct app *a);
void app_set_writer(struct app *a, void *data, void (*cb)(void*, char const*, size_t));
void app_set_window_size(struct app *a);
void do_command(struct app *a, char *line);
void do_snote(struct app *a, char *line);
void do_timer(struct app *a);
void do_keyboard(struct app *, long);
void do_mrs(struct app *, char const* host, struct addrinfo const* ai);

#endif
