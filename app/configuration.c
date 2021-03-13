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
                    "         [-H irc_host]\n"
                    "         [-P irc_port]\n"
                    "         [-N irc_nick]\n"
                    "         [-X irc_password]\n"
                    "         LUA_FILE\n");
    exit(EXIT_FAILURE);
}

struct configuration load_configuration(int argc, char **argv)
{
    struct configuration cfg = {};

    int opt;
    while ((opt = getopt(argc, argv, "h:p:H:P:X:N:")) != -1) {
        switch (opt) {
        case 'h': cfg.console_node = optarg; break;
        case 'p': cfg.console_service = optarg; break;
        case 'N': cfg.irc_nick = optarg; break;
        case 'X': cfg.irc_pass = optarg; break;
        case 'P': cfg.irc_service = optarg; break;
        case 'H': cfg.irc_node = optarg; break;
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
