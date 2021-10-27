#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdnoreturn.h>
#include <unistd.h>

#include "configuration.h"
#include "config.h"

noreturn static void usage(void) 
{
    fprintf(stderr,
    "usage: snowcone\n"
    "         -S socat_address\n"
    "         -N nick\n"
    "         [-U user]\n"
    "         [-G gecos]\n"
    "         [-X password]\n"
    "         [-O oper_username]\n"
    "         [-K challenge_key]\n"
    "         [-M sasl_mechanism]\n"
    "         [-E sasl_username]\n"
    "         [-C capabilities]\n"
    "         [-L init.lua]\n"
    "         [-f network.lua]\n"
    "         [-l console_host]\n"
    "         [-p console_port]\n"
    "         [-h]\n"
    );
    exit(EXIT_FAILURE);
}

struct configuration load_configuration(int argc, char **argv)
{
    struct configuration cfg = {};

    cfg.lua_filename = DATAROOTDIR "/snowcone/lua/init.lua";

    cfg.irc_pass = getenv("IRC_PASSWORD");
    cfg.irc_challenge_password = getenv("IRC_CHALLENGE_PASSWORD");
    cfg.irc_sasl_password = getenv("IRC_SASL_PASSWORD");
    cfg.irc_oper_password = getenv("IRC_OPER_PASSWORD");

    int opt;
    while ((opt = getopt(argc, argv, "f:hl:p:C:D:S:X:N:U:G:L:K:O:M:E:Z:")) != -1) {
        switch (opt) {
        case 'h': usage();
        case 'f': cfg.network_filename = optarg; break;
        case 'l': cfg.console_node = optarg; break;
        case 'p': cfg.console_service = optarg; break;
        case 'C': cfg.irc_capabilities = optarg; break;
        case 'E': cfg.irc_sasl_username = optarg; break;
        case 'G': cfg.irc_gecos = optarg; break;
        case 'D': cfg.irc_sasl_key = optarg; break;
        case 'K': cfg.irc_challenge_key = optarg; break;
        case 'L': cfg.lua_filename = optarg; break;
        case 'N': cfg.irc_nick = optarg; break;
        case 'M': cfg.irc_sasl_mechanism = optarg; break;
        case 'O': cfg.irc_oper_username = optarg; break;
        case 'S': cfg.irc_socat = optarg; break;
        case 'U': cfg.irc_user = optarg; break;
        case 'X': cfg.irc_pass = optarg; break;
        case 'Z': cfg.irc_sasl_authzid = optarg; break;
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

    if (NULL != cfg.irc_sasl_mechanism &&
        strcmp("PLAIN", cfg.irc_sasl_mechanism) &&
        strcmp("EXTERNAL", cfg.irc_sasl_mechanism) &&
        strcmp("ECDSA-NIST256P-CHALLENGE", cfg.irc_sasl_mechanism) &&
        strcmp("ECDH-X25519-CHALLENGE", cfg.irc_sasl_mechanism) &&
        strcmp("SCRAM-SHA-1", cfg.irc_sasl_mechanism) &&
        strcmp("SCRAM-SHA-256", cfg.irc_sasl_mechanism) &&
        strcmp("SCRAM-SHA-512", cfg.irc_sasl_mechanism))
    {
        fprintf(stderr, "SASL mechanism should be PLAIN, EXTERNAL, ECDSA-NIST256P-CHALLENGE, or ECDH-X25519-CHALLENGE (-M).\n");
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
