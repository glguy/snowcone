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

/**
 * Parses the given IRC message into a structured format.
 * The original message is mangled to store string fragments
 * that are pointed to by the structured message type.
 * 
 * Returns zero for success, non-zero for parse error.
 */
int parse_irc_message(char *msg, struct ircmsg *out);

#endif
