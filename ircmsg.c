#include <string.h>
#include <stdbool.h>
#include <stdio.h>
#include "ircmsg.h"

static char *word(char **msg)
{
    char *start = *msg;

    if (NULL == start || '\0' == *start) return NULL;

    char *end = strchr(start, ' ');
    
    if (NULL == end)
    {
        *msg = NULL;
        return start;
    }

    *end++ = '\0';
    while (' ' == *end) end++;
    *msg = end;

    return start;
}

int parse_irc_message(struct ircmsg *out, char *msg)
{
    /* MESSAGE TAGS */
    if (*msg == '@') 
    {
        msg++;

        char *tagpart = word(&msg);
        if (NULL == tagpart) return 1;

        char const* delim = ";";
        int i = 0;
        for (char *keyval = strtok(tagpart, delim); keyval; keyval = strtok(NULL, delim))
        {
            if (i >= MAX_MSG_TAGS) return 2;
            
            char *key = strsep(&keyval, "=");
            out->tags[i] = (struct tag) {
                .key = key,
                .val = keyval,
            };

            i++;
        }
        out->tags_n = i;
    }
    else
    {
        out->tags_n = 0;
    }

    /* MESSAGE SOURCE */
    if (*msg == ':')
    {
        msg++;
        char *source = word(&msg);
        if (NULL == source) return 3;
        out->source = source;
    }
    else
    {
        out->source = NULL;
    }

    char *command = word(&msg);
    if (NULL == command) return 4;
    out->command = command;

    if (msg == NULL) {
        out->args_n = 0;
        return 0;
    }

    for (int i = 0;; i++) 
    {
        if (*msg == ':')
        {
            out->args[i] = msg+1;
            out->args_n = i+1;
            return 0;
        }

        if (i+1 == MAX_ARGS)
        {
            out->args[i] = msg;
            out->args_n = i+1;
            return 0;
        }

        char *arg = word(&msg);
        out->args[i] = arg;

        if (NULL == msg)
        {
            out->args_n = i+1;
            return 0;
        }
    }

    return 0;
}