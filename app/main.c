#define _XOPEN_SOURCE 600
#define _XOPEN_SOURCE_EXTENDED
#define _DARWIN_C_SOURCE

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

static void on_timer(uv_timer_t *handle);

static void on_timer(uv_timer_t *timer)
{
    struct app *a = timer->loop->data;
    do_timer(a);
}

/* FILE WATCHER ******************************************************/

static void on_file(uv_fs_event_t *handle, char const *filename, int events, int status);

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

    uv_loop_t loop = {};
    uv_loop_init(&loop);

    struct app *a = app_new(&loop, &cfg);
    loop.data = a;

    uv_poll_t input;
    uv_poll_init(&loop, &input, STDIN_FILENO);
    uv_poll_start(&input, UV_READABLE, on_stdin);

    uv_signal_t winch;
    uv_signal_init(&loop, &winch);
    uv_signal_start(&winch, on_winch, SIGWINCH);

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
    uv_fs_event_init(&loop, &files);
    char *lua_dir = strdup(cfg.lua_filename);
    uv_fs_event_start(&files, &on_file, dirname(lua_dir), 0);
    free(lua_dir);

    uv_timer_t timer;
    uv_timer_init(&loop, &timer);
    uv_timer_start(&timer, on_timer, timer_ms, timer_ms);

    uv_run(&loop, UV_RUN_DEFAULT);

cleanup:

    uv_loop_close(&loop);
    app_free(loop.data);

    endwin();

    return 0;
}
