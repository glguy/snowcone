#include <assert.h>
#include <stdlib.h>

#include <uv.h>

#include "app.h"
#include "buffer.h"
#include "read-line.h"
#include "tcp-server.h"
#include "write.h"

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
        fprintf(stderr, "failed to resolve %s: %s\n", node, uv_strerror(res));
        exit(1);
    }
    
    for (struct addrinfo *ai = req.addrinfo; ai; ai = ai->ai_next)
    {
        uv_tcp_t *tcp = malloc(sizeof *tcp);
        if (NULL == tcp)
        {
            perror("malloc");
            exit(EXIT_FAILURE);
        }

        res = uv_tcp_init(loop, tcp);
        if (res < 0)
        {
            fprintf(stderr, "failed to create socket: %s\n", uv_strerror(res));
            exit(EXIT_FAILURE);
        }

        res = uv_tcp_bind(tcp, ai->ai_addr, 0);
        if (res < 0)
        {
            fprintf(stderr, "failed to bind: %s\n", uv_strerror(res));
            exit(EXIT_FAILURE);
        } 

        res = uv_listen((uv_stream_t*)tcp, SOMAXCONN, &on_new_connection);
        if (res < 0)
        {
            fprintf(stderr, "failed to listen: %s\n", uv_strerror(res));
            exit(EXIT_FAILURE);
        } 
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
        .read = &on_line,
        .read_data = client,
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

    do_command(a, msg, stream, to_write);
}
