#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>

#include <ircmsg.h>

static bool
strcheck(char const* x, char const* y)
{
    return ((x == NULL) != (y == NULL)) || (x && strcmp(x,y)); 
}

static void
testcase(int testid, char *input, struct ircmsg *expected)
{
    struct ircmsg got;
    int result = parse_irc_message(&got, input);

    if (result != 0 && expected == NULL)
    {
        return;
    }

    if (result == 0 && expected == NULL)
    {
        fprintf(stderr, "Test %d failed, parsed when it shouldn't have\n", testid);
        exit(EXIT_FAILURE);        
    }

    if (result != 0 && expected != NULL)
    {
        fprintf(stderr, "Test %d failed, parse error %d\n", testid, result);
        exit(EXIT_FAILURE);
    }

    if (got.tags_n != expected->tags_n)
    {
        fprintf(stderr, "Test %d failed, tag count mismatch, expected: %d, got: %d\n", testid, expected->tags_n, got.tags_n);
        exit(EXIT_FAILURE);
    }

    if (got.args_n != expected->args_n)
    {
        fprintf(stderr, "Test %d failed, arg count mismatch, expected: %d, got: %d\n", testid, expected->args_n, got.args_n);
        exit(EXIT_FAILURE);
    }

    if (strcheck(expected->source, got.source))
    {
        fprintf(stderr, "Test %d failed, prefix mismatch, expected: %s, got: %s\n", testid, expected->source, got.source);
        exit(EXIT_FAILURE);
    }

    if (strcheck(expected->command, got.command))
    {
        fprintf(stderr, "Test %d failed, command mismatch, expected: %s, got: %s\n", testid, expected->command, got.command);
        exit(EXIT_FAILURE);
    }

    for (int i = 0; i < got.tags_n; i++)
    {
        if (strcheck(expected->tags[i].key, got.tags[i].key))
        {
            fprintf(stderr, "Test %d failed, tag %d mismatch, expected: %s, got: %s\n", testid, i,expected->tags[i].key, got.tags[i].key);
            exit(EXIT_FAILURE);
        }
        if (strcheck(expected->tags[i].val, got.tags[i].val))
        {
            fprintf(stderr, "Test %d failed, val %d mismatch, expected: %s, got: %s\n", testid, i,expected->tags[i].val, got.tags[i].val);
            exit(EXIT_FAILURE);
        }
    }

    for (int i = 0; i < got.args_n; i++)
    {
        if (strcheck(expected->args[i], got.args[i]))
        {
            fprintf(stderr, "Test %d failed, arg %d mismatch, expected: %s, got: %s\n", testid, i,expected->args[i], got.args[i]);
            exit(EXIT_FAILURE);
        }
    }
}

int main(void)
{
    {
        struct ircmsg expect = {
            .command = "cmd",
            .args_n = 0,
        };
        char input[] = "cmd";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .command = "cmd",
            .args_n = 1,
            .args = {"arg"},
        };
        char input[] = "cmd arg";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .command = "cmd",
            .args_n = 1,
            .args = {"arg"},
        };
        char input[] = "  cmd  arg  ";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .command = "command",
            .args_n = 2,
            .args = {"arg", "arg2"},
        };
        char input[] = "command arg :arg2";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .command = "command",
            .args_n = 2,
            .args = {"arg", "arg2  more"},
        };
        char input[] = "command arg :arg2  more";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .command = "command",
            .args_n = 1,
            .args = {"arg:arg2"},
        };
        char input[] = "command arg:arg2";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .command = "command",
            .args_n = 15,
            .args = {"1","2","3","4","5","6","7","8","9","10","11","12","13","14","15 16"},
        };
        char input[] = "command 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .command = "command",
            .args_n = 15,
            .args = {"1","2","3","4","5","6","7","8","9","10","11","12","13","14","15 16"},
        };
        char input[] = "command 1 2 3 4 5 6 7 8 9 10 11 12 13 14 :15 16";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .source = "prefix",
            .command = "command",
            .args_n = 2,
            .args = {"arg", "arg2 "},
        };
        char input[] = ":prefix command arg :arg2 ";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .source = "prefix",
            .command = "command",
            .args_n = 2,
            .args = {"arg", ""},
        };
        char input[] = ":prefix command arg :";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .source = "prefix",
            .command = "command",
            .args_n = 2,
            .args = {"arg", ""},
        };
        char input[] = ":prefix command arg :";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 1,
            .tags[0].key = "key",
            .tags[0].val = "val",
            .source = "prefix",
            .command = "command",
            .args_n = 2,
            .args = {"arg", ""},
        };
        char input[] = "@key=val :prefix command arg :";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 2,
            .tags[0].key = "key",
            .tags[0].val = "val",
            .tags[1].key = "yek",
            .tags[1].val = "eulav",
            .source = "prefix",
            .command = "command",
        };
        char input[] = "@key=val;yek=eulav :prefix command";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 2,
            .tags[0].key = "key",
            .tags[1].key = "yek",
            .tags[1].val = "eulav",
            .source = "prefix",
            .command = "command",
        };
        char input[] = "@key;yek=eulav :prefix command";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 2,
            .tags[0].key = "key",
            .tags[1].key = "yek",
            .tags[1].val = "; \\\r\n",
            .source = "prefix",
            .command = "command",
        };
        char input[] = "@key;yek=\\:\\s\\\\\\r\\n :prefix command";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 1,
            .tags[0].key = "key",
            .tags[0].val = "",
            .source = "pfx",
            .command = "command",
        };
        char input[] = "@key= :pfx command";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 1,
            .tags[0].key = "key",
            .tags[0].val = "x",
            .command = "command",
        };
        char input[] = "@key=x\\ command";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 1,
            .tags[0].key = "key",
            .tags[0].val = "x",
            .command = "command",
        };
        char input[] = "@key=\\x command";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 1,
            .tags[0].key = "k\\s",
            .tags[0].val = "x",
            .command = "command",
        };
        char input[] = "@k\\s=x command";
        testcase(__LINE__, input, &expect);
    }

    {
        struct ircmsg expect = {
            .tags_n = 2,
            .tags[0].key = "key",
            .tags[0].val = "",
            .tags[1].key = "yek",
            .tags[1].val = "",
            .command = "command",
        };
        char input[] = "@key=;yek= command";
        testcase(__LINE__, input, &expect);
    }

    {
        char input[] = "@ :pfx command";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = "@; command";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = ": command";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = "@=value command";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = "@key=value; command";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = "@key=value";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = "@key=value;";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = ":";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = "";
        testcase(__LINE__, input, NULL);
    }

    {
        char input[] = "   ";
        testcase(__LINE__, input, NULL);
    }
}