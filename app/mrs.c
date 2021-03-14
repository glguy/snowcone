#include <stdlib.h>
#include <sys/socket.h>
#include <assert.h>

#include "app.h"
#include "mrs.h"

static const uint64_t mrs_update_ms = 30 * 1000;

static void on_mrs_timer(uv_timer_t *timer);
static void on_mrs_getaddrinfo(uv_getaddrinfo_t *, int, struct addrinfo *);

void start_mrs_timer(uv_loop_t *loop)
{
    uv_timer_t *timer = malloc(sizeof *timer);
    uv_timer_init(loop, timer);
    uv_timer_start(timer, on_mrs_timer, 0, mrs_update_ms);
}

static void on_mrs_timer(uv_timer_t *timer)
{
    struct addrinfo hints = {.ai_socktype = SOCK_STREAM};

    uv_getaddrinfo_t *req;
    uv_loop_t * const loop = timer->loop;

#define ROTATION(NAME, HOST) \
    req = malloc(sizeof *req); \
    req->data = NAME; \
    assert(0 == uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, HOST, NULL, &hints));

    hints.ai_family = PF_UNSPEC;
    ROTATION("", "chat.freenode.net")
    ROTATION("AU", "chat.au.freenode.net")
    ROTATION("EU", "chat.eu.freenode.net")
    ROTATION("US", "chat.us.freenode.net")
    hints.ai_family = PF_INET;
    ROTATION("IPV4", "chat.ipv4.freenode.net")
    hints.ai_family = PF_INET6;
    ROTATION("IPV6", "chat.ipv6.freenode.net")

#undef ROTATION
}

static void on_mrs_getaddrinfo(uv_getaddrinfo_t *req, int status, struct addrinfo *ai)
{
    struct app * const a = req->loop->data;
    char const* const name = req->data;

    if (0 == status)
    {
        do_mrs(a, name, ai);
        uv_freeaddrinfo(ai);
    }
    free(req);
}
