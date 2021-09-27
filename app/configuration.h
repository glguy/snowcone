#ifndef CONFIGURATION_H
#define CONFIGURATION_H

struct configuration
{
    char const* console_node;
    char const* console_service;
    char const* lua_filename;
    char const* irc_socat;
    char const* irc_nick;
    char const* irc_pass;
    char const* irc_user;
    char const* irc_gecos;
};

struct configuration load_configuration(int argc, char **argv);

#endif
