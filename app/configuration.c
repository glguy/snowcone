#include <stdio.h>
#include <stdlib.h>
#include <stdnoreturn.h>
#include <unistd.h>

#include "configuration.h"
#include "config.h"

noreturn static void usage(void) 
{
    fprintf(stderr,
    "usage: snowcone\n"
    "         -S irc_socat\n"
    "         -N irc_nick\n"
    "         [-U irc_user]\n"
    "         [-G irc_gecos]\n"
    "         [-X irc_password]\n"
    "         [-O irc_oper]\n"
    "         [-K irc_challenge_key]\n"
    "         [-L init.lua]\n"
    "         [-h console_host]\n"
    "         [-p console_port]\n"
    );
    exit(EXIT_FAILURE);
}

struct configuration load_configuration(int argc, char **argv)
{
    struct configuration cfg = {};

    cfg.irc_pass = getenv("IRC_PASSWORD");
    cfg.lua_filename = DATAROOTDIR "/snowcone/lua/init.lua";
    cfg.irc_challenge_password = getenv("IRC_CHALLENGE_PASSWORD");

    int opt;
    while ((opt = getopt(argc, argv, "h:p:S:X:N:U:G:L:K:O:")) != -1) {
        switch (opt) {
        case 'h': cfg.console_node = optarg; break;
        case 'p': cfg.console_service = optarg; break;
        case 'G': cfg.irc_gecos = optarg; break;
        case 'K': cfg.irc_challenge_key = optarg; break;
        case 'L': cfg.lua_filename = optarg; break;
        case 'N': cfg.irc_nick = optarg; break;
        case 'O': cfg.irc_oper = optarg; break;
        case 'S': cfg.irc_socat = optarg; break;
        case 'U': cfg.irc_user = optarg; break;
        case 'X': cfg.irc_pass = optarg; break;
        default: usage();
        }
    }

    argv += optind;
    argc -= optind;

    int show_usage = 0;

    if (NULL == cfg.irc_nick)
    {
        fprintf(stderr, "IRC nickname required (-N).\n");
        show_usage = 1;
    }

    if (NULL == cfg.irc_socat)
    {
        fprintf(stderr, "socat connection argument required (-S).\n");
        show_usage = 1;
    }

    if (0 != argc)
    {
        fprintf(stderr, "Unexpected positional argument (use -L for lua path).\n");
        show_usage = 1;
    }

    if (show_usage) {
        usage();
    }

    return cfg;
}
