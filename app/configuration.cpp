#include "configuration.hpp"

#include "config.hpp"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <unistd.h>

[[noreturn]] static void usage(void) 
{
    std::cerr <<
    "usage: snowcone\n"
    "         -S socat_address\n"
    "         -N nick\n"
    "         [-U user]\n"
    "         [-G gecos]\n"
    "         [-O oper_username]\n"
    "         [-K challenge_key]\n"
    "         [-M sasl_mechanism]\n"
    "         [-E sasl_username]\n"
    "         [-D sasl_keyfile]\n"
    "         [-Z sasl_authzid]\n"
    "         [-C capabilities]\n"
    "         [-L init.lua]\n"
    "         [-f network.lua]\n"
    "         [-h]\n";
    exit(EXIT_FAILURE);
}

configuration load_configuration(int argc, char** argv)
{
    configuration cfg {};

    cfg.lua_filename = DATAROOTDIR "/snowcone/lua/init.lua";

    cfg.irc_pass = getenv("IRC_PASSWORD");
    cfg.irc_challenge_password = getenv("IRC_CHALLENGE_PASSWORD");
    cfg.irc_sasl_password = getenv("IRC_SASL_PASSWORD");
    cfg.irc_oper_password = getenv("IRC_OPER_PASSWORD");

    char const* const flags = ":C:D:E:f:G:hK:L:M:N:O:S:U:Z:";
    int opt;
    while ((opt = getopt(argc, argv, flags)) != -1) {
        switch (opt) {
        default: abort();
        case '?': std::cerr << "Unknown flag: " << char(optopt) << std::endl; usage();
        case ':': std::cerr << "Missing flag argument: " << char(optopt) << std::endl; usage();
        case 'h': usage();
        case 'C': cfg.irc_capabilities      = optarg; break;
        case 'D': cfg.irc_sasl_key          = optarg; break;
        case 'E': cfg.irc_sasl_username     = optarg; break;
        case 'f': cfg.network_filename      = optarg; break;
        case 'G': cfg.irc_gecos             = optarg; break;
        case 'K': cfg.irc_challenge_key     = optarg; break;
        case 'L': cfg.lua_filename          = optarg; break;
        case 'M': cfg.irc_sasl_mechanism    = optarg; break;
        case 'N': cfg.irc_nick              = optarg; break;
        case 'O': cfg.irc_oper_username     = optarg; break;
        case 'S': cfg.irc_socat             = optarg; break;
        case 'U': cfg.irc_user              = optarg; break;
        case 'Z': cfg.irc_sasl_authzid      = optarg; break;
        }
    }

    argv += optind;
    argc -= optind;

    bool show_usage = false;

    if (nullptr == cfg.irc_nick) {
        std::cerr << "IRC nickname required (-N).\n";
        show_usage = true;
    }

    if (nullptr == cfg.irc_socat) {
        std::cerr << "socat connection argument required (-S).\n";
        show_usage = true;
    }

    if (nullptr != cfg.irc_sasl_mechanism &&
        0 != strcmp("PLAIN", cfg.irc_sasl_mechanism) &&
        0 != strcmp("EXTERNAL", cfg.irc_sasl_mechanism) &&
        0 != strcmp("ECDSA-NIST256P-CHALLENGE", cfg.irc_sasl_mechanism) &&
        0 != strcmp("ECDH-X25519-CHALLENGE", cfg.irc_sasl_mechanism) &&
        0 != strcmp("SCRAM-SHA-1", cfg.irc_sasl_mechanism) &&
        0 != strcmp("SCRAM-SHA-256", cfg.irc_sasl_mechanism) &&
        0 != strcmp("SCRAM-SHA-512", cfg.irc_sasl_mechanism))
    {
        std::cerr << "SASL mechanism should be PLAIN, EXTERNAL, ECDSA-NIST256P-CHALLENGE, ECDH-X25519-CHALLENGE, SCRAM-SHA-1, SCRAM-SHA-256, SCRAM-SHA-512 (-M).\n";
        show_usage = true;
    }

    if (0 != argc) {
        std::cerr << "Unexpected positional argument (use -L for lua path).\n";
        show_usage = true;
    }

    if (show_usage) {
        usage();
    }

    return cfg;
}
