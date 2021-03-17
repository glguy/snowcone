#include <stdlib.h>
#include <stdio.h>
#include <stdnoreturn.h>
#include <unistd.h>

#include "configuration.h"

noreturn static void usage(void) 
{
    fprintf(stderr, "usage: snowcode\n"
                    "         [-h console_host]\n"
                    "         [-p console_port]\n"
                    "         [-S irc_socat]\n"
                    "         [-N irc_nick]\n"
                    "         [-X irc_password]\n"
                    "         LUA_FILE\n");
    exit(EXIT_FAILURE);
}

struct configuration load_configuration(int argc, char **argv)
{
    struct configuration cfg = {};

    int opt;
    while ((opt = getopt(argc, argv, "h:p:S:X:N:")) != -1) {
        switch (opt) {
        case 'h': cfg.console_node = optarg; break;
        case 'p': cfg.console_service = optarg; break;
        case 'N': cfg.irc_nick = optarg; break;
        case 'X': cfg.irc_pass = optarg; break;
        case 'S': cfg.irc_socat = optarg; break;
        default: usage();
        }
    }

    argv += optind;
    argc -= optind;

    if (argc != 1)
    {
        usage();
    }

    cfg.lua_filename = argv[0];

    return cfg;
}
