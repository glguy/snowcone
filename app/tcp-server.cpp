#include "tcp-server.hpp"

#include "app.hpp"
#include "read-line.hpp"
#include "uvaddrinfo.hpp"
#include "write.hpp"

#include <ncurses.h>
#include <uv.h>

#include <cstdlib>
#include <iostream>

/* TCP SERVER ********************************************************/

namespace {

void on_new_connection(uv_stream_t* server, int status)
{
    if (status < 0) {
        std::cerr << "New connection error " << uv_strerror(status) << std::endl;
        uv_close_xx(server);
        return;
    }

    auto client = new uv_tcp_t;
    uvok(uv_tcp_init(server->loop, client));
    uvok(uv_accept(server, reinterpret_cast<uv_stream_t*>(client)));

    readline_start(client, [](uv_stream_t *stream, char *msg) {
        if (msg) {
            auto a = static_cast<app*>(stream->loop->data);
            a->do_command(msg, stream);
        }
    });
}

}

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
        std::cerr << "failed to resolve " << a->cfg->console_node << ": " << uv_strerror(res) << std::endl;
        return 1;
    }

    AddrInfo const ais {req.addrinfo};

    a->listeners.reserve(std::distance(ais.begin(), ais.end()));

    // Bind all of the addresses
    for (auto const& ai : ais)
    {
        auto tcp = &a->listeners.emplace_back();
        uvok(uv_tcp_init(&a->loop, tcp));

        res = uv_tcp_bind(tcp, ai.ai_addr, 0);
        if (res < 0)
        {
            endwin();
            std::cerr << "failed to bind: " << uv_strerror(res) << std::endl;
            goto teardown;
        }

        res = uv_listen(reinterpret_cast<uv_stream_t*>(tcp), SOMAXCONN, &on_new_connection);
        if (res < 0)
        {
            endwin();
            std::cerr << "failed to listen: " << uv_strerror(res) << std::endl;
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
