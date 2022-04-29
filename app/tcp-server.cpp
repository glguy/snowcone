#include <assert.h>
#include <stdlib.h>

#include <uv.h>
#include <ncurses.h>

#include <ranges>

#include "app.hpp"
#include "read-line.hpp"
#include "tcp-server.hpp"
#include "uvaddrinfo.hpp"
#include "write.hpp"

/* TCP SERVER ********************************************************/

static void on_new_connection(uv_stream_t *server, int status);

int start_tcp_server(struct app *a)
{
    addrinfo hints {0};
    hints.ai_flags = AI_PASSIVE;
    hints.ai_family = PF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    // Resolve the addresses
    uv_getaddrinfo_t req;
    int res = uv_getaddrinfo(&a->loop, &req, nullptr, a->cfg->console_node, a->cfg->console_service, &hints);
    if (res < 0)
    {
        endwin();
        fprintf(stderr, "failed to resolve %s: %s\n", a->cfg->console_node, uv_strerror(res));
        return 1;
    }
    
    AddrInfo const ais {req.addrinfo};

    a->listeners.reserve(std::ranges::distance(ais));

    // Bind all of the addresses
    for (auto const& ai : ais)
    {
        auto tcp = &a->listeners.emplace_back();
        uvok(uv_tcp_init(&a->loop, tcp));

        res = uv_tcp_bind(tcp, ai.ai_addr, 0);
        if (res < 0)
        {
            endwin();
            fprintf(stderr, "failed to bind: %s\n", uv_strerror(res));
            goto teardown;
        } 

        res = uv_listen(reinterpret_cast<uv_stream_t*>(tcp), SOMAXCONN, &on_new_connection);
        if (res < 0)
        {
            endwin();
            fprintf(stderr, "failed to listen: %s\n", uv_strerror(res));
            goto teardown;
        } 
    }

    return 0;

teardown:
    for (auto && x : a->listeners) {
        uv_close_xx(&x);
    }
    return 1;
}

static void on_new_connection(uv_stream_t *server, int status)
{
    if (status < 0) {
        fprintf(stderr, "New connection error %s\n", uv_strerror(status));
        uv_close_xx(server);
        return;
    }

    auto client = new uv_tcp_t;
    uvok(uv_tcp_init(server->loop, client));

    uvok(uv_accept(server, reinterpret_cast<uv_stream_t*>(client)));

    readline_start(client, [](uv_stream_t *stream, char *msg) {
        if (msg) {
            auto a = static_cast<app*>(stream->loop->data);
            do_command(a, msg, stream);
        }
    });
}
