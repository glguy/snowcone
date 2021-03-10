#ifndef IRCMSG_H
#define IRCMSG_H

#define MAX_MSG_TAGS 8
#define MAX_ARGS 15

struct tag
{
    char const* key;
    char const* val;
};

struct ircmsg
{
    struct tag tags[MAX_MSG_TAGS];
    char const* source;
    char const* command;
    char const* args[MAX_ARGS];
    int tags_n, args_n;
};

int parse_irc_message(struct ircmsg *out, char *msg);

#endif