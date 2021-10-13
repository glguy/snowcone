#include <assert.h>
#include <stdlib.h>

#include <uv.h>

#include "app.h"
#include "read-line.h"
#include "tcp-server.h"
#include "write.h"

/* TCP SERVER ********************************************************/

static void on_new_connection(uv_stream_t *server, int status);
static void on_line(uv_stream_t *, char *);
static void free_handle(uv_handle_t *handle);

int start_tcp_server(struct app *a)
{
    struct addrinfo const hints = {
        .ai_flags = AI_PASSIVE,
        .ai_family = PF_UNSPEC,
        .ai_socktype = SOCK_STREAM,
    };

    // Resolve the addresses
    uv_getaddrinfo_t req;
    int res = uv_getaddrinfo(&a->loop, &req, NULL, a->cfg->console_node, a->cfg->console_service, &hints);
    if (res < 0)
    {
        fprintf(stderr, "failed to resolve %s: %s\n", a->cfg->console_node, uv_strerror(res));
        return 1;
    }
    
    // Count the addresses
    size_t n = 0;
    for (struct addrinfo *ai = req.addrinfo; ai; ai = ai->ai_next)
    {
        n++;
    }

    // Allocate temporary storage for tracking all the inprogress sockets
    a->listeners = calloc(n, sizeof a->listeners[0]);
    assert(a->listeners);
    a->listeners_len = n;

    // Allocate all tcp streams
    size_t i = 0;
    for (struct addrinfo *ai = req.addrinfo; ai; ai = ai->ai_next, i++)
    {
        res = uv_tcp_init(&a->loop, &a->listeners[i]);
        assert(0 == res);
    }

    // Bind all of the addresses
    i = 0;
    for (struct addrinfo *ai = req.addrinfo; ai; ai = ai->ai_next, i++)
    {
        uv_tcp_t *tcp = &a->listeners[i];
        res = uv_tcp_bind(tcp, ai->ai_addr, 0);
        if (res < 0)
        {
            fprintf(stderr, "failed to bind: %s\n", uv_strerror(res));
            goto teardown;
        } 

        res = uv_listen((uv_stream_t*)tcp, SOMAXCONN, &on_new_connection);
        if (res < 0)
        {
            fprintf(stderr, "failed to listen: %s\n", uv_strerror(res));
            goto teardown;
        } 
    }

    uv_freeaddrinfo(req.addrinfo);
    return 0;

teardown:
    uv_freeaddrinfo(req.addrinfo);
    for (i = 0; i < n; i++)
    {
        uv_close((uv_handle_t*)&a->listeners[i], NULL);
    }
    return 1;
}

static void on_new_connection(uv_stream_t *server, int status)
{
    if (status < 0) {
        fprintf(stderr, "New connection error %s\n", uv_strerror(status));
        uv_close((uv_handle_t*)server, NULL);
        return;
    }

    struct readline_data *data = calloc(1, sizeof *data);
    assert(data);
    data->line_cb = on_line;

    uv_tcp_t *client = malloc(sizeof *client);
    assert(client);
    client->data = data;

    int res = uv_tcp_init(server->loop, client);
    assert(0 == res);

    res = uv_accept(server, (uv_stream_t*)client);
    assert(0 == res);

    res = uv_read_start((uv_stream_t *)client, readline_alloc, readline_cb);
    assert(0 == res);
}

static void on_line(uv_stream_t *stream, char *msg)
{
    if (msg)
    {
        struct app *a = stream->loop->data;
        do_command(a, msg, stream);
    }
}
