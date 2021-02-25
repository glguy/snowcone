#ifndef APP_H
#define APP_H

struct app;

struct app *app_new(char const *logic);
void app_free(struct app *a);
void app_reload(struct app *a);

void do_command(struct app *a, char *line);
void do_snote(struct app *a, char *line);
void do_timer(struct app *a);

#endif
