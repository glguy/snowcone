#include <string.h>

#include "ircmsg.h"

static char *word(char **msg)
{
    if (NULL == *msg || '\0' == **msg) return NULL;
    char *start = strsep(msg, " ");

    if (NULL != *msg)
    {
        while (' ' == **msg) (*msg)++;
        if ('\0' == **msg) *msg = NULL;
    }
    return start;
}

static void unescape_tag_value(char *val)
{
    char *write = val;
    for (char *cursor = val; *cursor; cursor++)
    {
        if (*cursor == '\\')
        {
            cursor++;
            switch (*cursor)
            {
                case ':' : *write++ = ';'    ; break;
                case 's' : *write++ = ' '    ; break;
                case 'r' : *write++ = '\r'   ; break;
                case 'n' : *write++ = '\n'   ; break;
                case '\0': *write   = '\0'   ; return;
                default  : *write++ = *cursor; break;
            }
        }
        else
        {
            *write++ = *cursor;
        }
    }
    *write = '\0';
}

static int
parse_tags(char *tagpart, struct ircmsg *out)
{
    char const* const delim = ";";
    char *last;
    int i = 0;

    while (tagpart)
    {
        if (' ' == *tagpart || '\0' == *tagpart)
        {
            return 2;
        }

        char *keyval = strsep(&tagpart, ";");

        if (i >= MAX_MSG_TAGS) return 1;
        char *key = strsep(&keyval, "=");
        if (NULL != keyval) unescape_tag_value(keyval);

        out->tags[i] = (struct tag) {
            .key = key,
            .val = keyval,
        };

        if ('\0' == *key)
        {
            return 1;
        }

        i++;
    }

    out->tags_n = i;
    return 0;
}

int
parse_irc_message(char *msg, struct ircmsg *out)
{
    /* Ignore leading space */
    while (*msg == ' ') msg++;

    /* MESSAGE TAGS */
    if (*msg == '@')
    {
        msg++;
        char *tagpart = word(&msg);
        if (NULL == tagpart || '\0' == *tagpart || NULL == msg) return 1;
        if (parse_tags(tagpart, out)) return 2;
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
        if (NULL == source || '\0' == *source) return 3;
        out->source = source;
    }
    else
    {
        out->source = NULL;
    }

    /* MESSAGE COMMANDS */
    char *command = word(&msg);
    if (NULL == command) return 4;
    out->command = command;

    /* MESSAGE ARGUMENTS */
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
