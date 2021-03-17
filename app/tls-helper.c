#define _GNU_SOURCE

#include <spawn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <uv.h>

#include "tls-helper.h"

static void tls_exit(uv_process_t *process, int64_t exit_status, int term_signal);

void tls_wrapper(uv_loop_t *loop, char const* socat, int sock)
{
    char *argv[4] = {};

    argv[0] = strdup("/usr/bin/socat");
    asprintf(&argv[1], "FD:%d", sock);
    argv[2] = strdup(socat);

    uv_stdio_container_t containers[] = {
        {.data.fd = STDIN_FILENO, .flags = UV_INHERIT_FD},
        {.data.fd = STDOUT_FILENO, .flags = UV_INHERIT_FD},
        {.data.fd = STDERR_FILENO, .flags = UV_INHERIT_FD},
        {.data.fd = sock, .flags = UV_IGNORE},
    };

    uv_process_options_t options = {
        .file = "/usr/bin/socat",
        .args = argv,
        .exit_cb = tls_exit,
        .stdio_count = sizeof containers / sizeof *containers,
        .stdio = containers,
    };

    uv_process_t *process = malloc(sizeof *process);
    uv_spawn(loop, process, &options);

    free(argv[0]);
    free(argv[1]);
    free(argv[2]);
}

static void tls_exit(uv_process_t *process, int64_t exit_status, int term_signal)
{
    free(process);
}
