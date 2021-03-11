#include "tcp-server.h"
#include "app.h"
#include "buffer.h"
#include "read-line.h"
#include "write.h"
#include <uv.h>

/* TCP SERVER ********************************************************/

static void on_new_connection(uv_stream_t *server, int status);
static void on_line(void *data, char *msg);

void start_tcp_server(uv_loop_t *loop, char const* node, char const* service)
{
    struct addrinfo hints = {
        .ai_flags = AI_PASSIVE,
        .ai_family = PF_UNSPEC,
        .ai_socktype = SOCK_STREAM,
    };
    uv_getaddrinfo_t req;
    int res = uv_getaddrinfo(loop, &req, NULL, node, service, &hints);
    if (res < 0)
    {
        fprintf(stderr, "failed to resolve tcp bind: %s\n", uv_err_name(res));
        exit(1);
    }
    
    for (struct addrinfo *ai = req.addrinfo; ai; ai = ai->ai_next)
    {
        uv_tcp_t *tcp = malloc(sizeof *tcp);
        uv_tcp_init(loop, tcp);
        uv_tcp_bind(tcp, ai->ai_addr, 0);
        uv_listen((uv_stream_t*)tcp, SOMAXCONN, &on_new_connection);
    }
    uv_freeaddrinfo(req.addrinfo);
}

static void on_new_connection(uv_stream_t *server, int status)
{
    if (status < 0) {
        fprintf(stderr, "New connection error %s\n", uv_strerror(status));
        return;
    }

    struct readline_data *data = malloc(sizeof *data);

    uv_tcp_t *client = malloc(sizeof *client);
    client->data = data;

    *data = (struct readline_data){
        .cb = &on_line,
        .cb_data = client,
    };

    uv_tcp_init(server->loop, client);
    uv_accept(server, (uv_stream_t*)client);
    uv_read_start((uv_stream_t *)client, my_alloc_cb, readline_cb);
}

static void on_line(void *data, char *msg)
{
    uv_stream_t *stream = data;
    uv_loop_t *loop = stream->loop;
    struct app *a = loop->data;

    app_set_writer(a, stream, to_write);
    do_command(a, msg);
    app_set_writer(a, NULL, NULL);
}
