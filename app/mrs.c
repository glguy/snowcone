#include <stdlib.h>

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
    static struct addrinfo const hints = {
        .ai_socktype = SOCK_STREAM,
    };
    static struct addrinfo const hints4 = {
        .ai_family = PF_INET,
        .ai_socktype = SOCK_STREAM,
    };
    static struct addrinfo const hints6 = {
        .ai_family = PF_INET6,
        .ai_socktype = SOCK_STREAM,
    };

    uv_getaddrinfo_t *req;
    uv_loop_t *loop = timer->loop;

#define ROTATION(NAME, HOST, HINTS) \
    req = malloc(sizeof *req); req->data = NAME; \
    uv_getaddrinfo(loop, req, &on_mrs_getaddrinfo, HOST, NULL, HINTS);

    ROTATION("", "chat.freenode.net", &hints)
    ROTATION("AU", "chat.au.freenode.net", &hints)
    ROTATION("EU", "chat.eu.freenode.net", &hints)
    ROTATION("US", "chat.us.freenode.net", &hints)
    ROTATION("IPV4", "chat.ipv4.freenode.net", &hints4)
    ROTATION("IPV6", "chat.ipv6.freenode.net", &hints6)

#undef ROTATION
}

static void on_mrs_getaddrinfo(uv_getaddrinfo_t *req, int status, struct addrinfo *ai)
{
    char const* const name = req->data;

    if (0 == status)
    {
        do_mrs(req->loop->data, name, ai);
        uv_freeaddrinfo(ai);
    }
    free(req);
}
