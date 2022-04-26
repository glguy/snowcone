#ifndef APP_H
#define APP_H

#include <netdb.h>
#include <stdlib.h>
#include <unistd.h>
#include <uv.h>

#include <vector>

extern "C" {
#include <lua.h>
#include <ircmsg.h>
}

#include "uverror.hpp"
#include "configuration.hpp"

struct uv_loop_xx : public ::uv_loop_t {
    uv_loop_xx() {
        uvok(uv_loop_init(this));
    }
    ~uv_loop_xx() {
        uv_print_all_handles(this, stdout);
        uvok(uv_loop_close(this));
    }
};

struct app
{
    lua_State *L;
    struct configuration *cfg;
    uv_stream_t *console;
    uv_stream_t *irc;
    uv_loop_xx loop;
    uv_poll_t input;
    uv_signal_t winch;
    std::vector<uv_tcp_t> listeners;
    bool closing;

    app(configuration * cfg)
    : cfg(cfg)
    , console(nullptr)
    , irc(nullptr)
    , loop()
    , input()
    , winch()
    , listeners()
    , closing(false)
    {
        loop.data = this;
        uvok(uv_poll_init(&loop, &input, STDIN_FILENO));
        uvok(uv_signal_init(&loop, &winch));
    }
};

struct app *app_new(struct configuration *cfg);
void app_free(struct app *a);
void app_set_irc(struct app *a, uv_stream_t *stream);
void app_clear_irc(struct app *a);
void app_set_window_size(struct app *a);
void do_command(struct app *a, char const* line, uv_stream_t *console);
void do_irc(struct app *a, struct ircmsg const*);
void do_irc_err(struct app *a, char const*);
void do_keyboard(struct app *, long);
void do_mouse(struct app *, int x, int y);

struct app **app_ref(lua_State *L);

#endif
