#include <assert.h>
#include <stdlib.h>

#include <uv.h>
#include <ncurses.h>

#include <memory>

#include "app.hpp"
#include "read-line.hpp"
#include "tcp-server.hpp"
#include "write.hpp"


/* TCP SERVER ********************************************************/

static void on_new_connection(uv_stream_t *server, int status);

int start_tcp_server(struct app *a)
{
    struct addrinfo hints {};
    hints.ai_flags = AI_PASSIVE;
    hints.ai_family = PF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    // Resolve the addresses
    uv_getaddrinfo_t req;
    int res = uv_getaddrinfo(&a->loop, &req, NULL, a->cfg->console_node, a->cfg->console_service, &hints);
    if (res < 0)
    {
        endwin();
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
    a->listeners.resize(n);

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
            endwin();
            fprintf(stderr, "failed to bind: %s\n", uv_strerror(res));
            goto teardown;
        } 

        res = uv_listen((uv_stream_t*)tcp, SOMAXCONN, &on_new_connection);
        if (res < 0)
        {
            endwin();
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
        uv_close((uv_handle_t*)&a->listeners[i], nullptr);
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

    auto client = new uv_tcp_t;

    int res = uv_tcp_init(server->loop, client);
    assert(0 == res);

    res = uv_accept(server, (uv_stream_t*)client);
    assert(0 == res);

    res = readline_start(reinterpret_cast<uv_stream_t *>(client), [](uv_stream_t *stream, char *msg) {
        if (msg) {
            auto a = static_cast<app*>(stream->loop->data);
            do_command(a, msg, stream);
        }
    });
    assert(0 == res);
}
