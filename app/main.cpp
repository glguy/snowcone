#define _XOPEN_SOURCE 600
#define _XOPEN_SOURCE_EXTENDED
#define _DARWIN_C_SOURCE

#include <iostream>

#include <assert.h>
#include <locale.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <curses.h>
#include <uv.h>

#include "app.hpp"
#include "configuration.hpp"
#include "irc.hpp"
#include "read-line.hpp"
#include "tcp-server.hpp"
#include "write.hpp"

static void on_winch(uv_signal_t* handle, int signum);

/* Main Input ********************************************************/

static void on_stdin(uv_poll_t *handle, int status, int events)
{
    struct app *a = static_cast<app *>(handle->loop->data);

    int key;
    mbstate_t ps = {};

    while(ERR != (key = getch()))
    {
        if (key == '\e') {
            key = getch();
            if (ERR == key) {
                do_keyboard(a, '\e');    
            } else {
                do_keyboard(a, -key);
            }
        } else if (KEY_MOUSE == key)
        {
            MEVENT ev;
            getmouse(&ev);
            if (ev.bstate == BUTTON1_CLICKED)
            {
                do_mouse(a, ev.y, ev.x);
            }
        } else if (KEY_RESIZE == key) {
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
    struct app *a = static_cast<app*>(handle->loop->data);
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

    FILE *tty = fopen("/dev/tty", "r+");
    if (NULL == tty) {
        perror("fopen");
        return 1;
    }

    SCREEN *scr = newterm(NULL, tty, stdin);
    if (NULL == scr) {
        fprintf(stderr, "newterm: Failed to initialize ncurses\n");
        return 1;
    }

    start_color();
    use_default_colors();
    nodelay(stdscr, TRUE); /* nonblocking input reads */
    raw(); /* pass through all they keys */
    noecho(); /* no echo input to screen */
    nonl(); /* no newline on pressing return */
    intrflush(stdscr, FALSE);
    keypad(stdscr, TRUE); /* process keyboard input escape sequences */
    curs_set(0); /* no cursor */
    mousemask(BUTTON1_CLICKED, NULL);
    set_escdelay(25);
    endwin();

    struct app *a = app_new(&cfg);

    uvok(uv_poll_start(&a->input, UV_READABLE, on_stdin));
    uvok(uv_signal_start(&a->winch, on_winch, SIGWINCH));

    /* start up networking */
    if (cfg.console_service != NULL)
    {
        if (start_tcp_server(a))
        {
            goto cleanup;
        }
    }

    if (*cfg.irc_socat != '\0' && start_irc(a))
    {
        goto cleanup;
    }

    // returns non-zero if stopped while handles are active
    uv_run(&a->loop, UV_RUN_DEFAULT);

cleanup:
    endwin();
    app_free(a);
    return 0;
}