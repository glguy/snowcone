#pragma once

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
    char const* irc_oper_username;
    char const* irc_oper_password;
    char const* irc_challenge_key;
    char const* irc_challenge_password;
    char const* irc_sasl_mechanism;
    char const* irc_sasl_username;
    char const* irc_sasl_password;
    char const* irc_capabilities;
    char const* network_filename;
    char const* irc_sasl_authzid;
    char const* irc_sasl_key;
};

configuration load_configuration(int argc, char **argv);
