#define _XOPEN_SOURCE 600
#define _XOPEN_SOURCE_EXTENDED
#define _DARWIN_C_SOURCE

#include <assert.h>
#include <libgen.h>
#include <locale.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <curses.h>
#include <uv.h>

#include "app.h"
#include "buffer.h"
#include "configuration.h"
#include "irc.h"
#include "read-line.h"
#include "tcp-server.h"
#include "write.h"

static const uint64_t timer_ms = 1000;

/* TIMER *************************************************************/

static void on_timer(uv_timer_t *timer)
{
    struct app *a = timer->loop->data;
    do_timer(a);
}

/* FILE WATCHER ******************************************************/

static void on_file(uv_fs_event_t *handle, char const *filename, int events, int status)
{
    struct app *a = handle->loop->data;
    app_reload(a);
}

/* Main Input ********************************************************/

static void on_stdin(uv_poll_t *handle, int status, int events)
{
    struct app *a = handle->loop->data;

    int key;
    mbstate_t ps = {};

    while(ERR != (key = getch()))
    {
        if (KEY_MOUSE == key)
        {
            MEVENT ev;
            getmouse(&ev);
            do_mouse(a, ev.y, ev.x);
        } else if (key > 0xff) {
            do_keyboard(a, -key);
        } else if (key < 0x80) {
            do_keyboard(a, key);
        } else {
            char c = key;
            wchar_t code;
            size_t r = mbrtowc(&code, &c, 1, &ps);
            if (r < (size_t)-2) {
                do_keyboard(a, code);
            }
        }
    }
}

/* Window size changes ***********************************************/

static void on_winch(uv_signal_t* handle, int signum)
{
    struct app *a = handle->loop->data;
    endwin();
    refresh();
    app_set_window_size(a);
}

/* MAIN **************************************************************/

int main(int argc, char *argv[])
{
    int r;
    struct configuration cfg = load_configuration(argc, argv);
    
    /* Configure ncurses */
    setlocale(LC_ALL, "");
    initscr(); 
    start_color();
    use_default_colors();
    nodelay(stdscr, TRUE); /* nonblocking input reads */
    cbreak(); /* no input line buffering */
    noecho(); /* no echo input to screen */
    nonl(); /* no newline on pressing return */
    intrflush(stdscr, FALSE);
    keypad(stdscr, TRUE); /* process keyboard input escape sequences */
    curs_set(0); /* no cursor */
    mousemask(BUTTON1_CLICKED, NULL);
    endwin();

    uv_loop_t loop = {};
    r = uv_loop_init(&loop);
    assert(0 == r);

    struct app *a = app_new(&loop, &cfg);
    loop.data = a;

    uv_poll_t input;
    r = uv_poll_init(&loop, &input, STDIN_FILENO);
    assert(0 == r);
    r = uv_poll_start(&input, UV_READABLE, on_stdin);
    assert(0 == r);

    uv_signal_t winch;
    r = uv_signal_init(&loop, &winch);
    assert(0 == r);
    r = uv_signal_start(&winch, on_winch, SIGWINCH);
    assert(0 == r);

    /* start up networking */
    if (cfg.console_service != NULL)
    {
        if (start_tcp_server(&loop, cfg.console_node, cfg.console_service))
        {
            goto cleanup;
        }
    }

    if (start_irc(&loop, &cfg))
    {
        goto cleanup;
    }

    uv_fs_event_t files;
    r = uv_fs_event_init(&loop, &files);
    assert(0 == r);
    char *lua_dir = strdup(cfg.lua_filename);
    r = uv_fs_event_start(&files, &on_file, dirname(lua_dir), 0);
    assert(0 == r);
    free(lua_dir);

    uv_timer_t timer;
    r = uv_timer_init(&loop, &timer);
    assert(0 == r);
    r = uv_timer_start(&timer, on_timer, timer_ms, timer_ms);
    assert(0 == r);

    // returns non-zero if stopped while handles are active
    (void)uv_run(&loop, UV_RUN_DEFAULT);

cleanup:
    // This won't be a clean close on manual uv_stop()
    (void)uv_loop_close(&loop);
    app_free(a);
    endwin();
    return 0;
}
