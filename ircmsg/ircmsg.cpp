#include <cstring>

#include "ircmsg.hpp"

namespace {
class parser {
    char *msg;

public:
    parser(char* msg) : msg(msg) {
        trim();
    }

    char* word() {
        auto start = strsep(&msg, " ");
        if (nullptr == start || '\0' == *start)
            throw irc_parse_error(6);
        trim();
        return start;
    }

    void trim() {
        if (msg) while (*msg == ' ') msg++;
    }

    bool match(char c) {
        if (nullptr != msg && c == *msg) {
            msg++;
            return true;
        }
        return false;
    }

    bool isempty() const {
        return nullptr == msg || *msg == '\0';
    }

    char* take() {
        auto tmp = msg;
        msg = nullptr;
        return tmp;
    }
};

void unescape_tag_value(char *val)
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

std::vector<tag> parse_tags(char* str)
{
    std::vector<tag> tags;

    do {
        auto val = strsep(&str, ";");
        auto key = strsep(&val, "=");
        if ('\0' == *key) {
            throw irc_parse_error(1);
        }
        if (nullptr != val) {
            unescape_tag_value(val);
        }

        tags.emplace_back(key, val);
    } while(nullptr != str);

    return tags;
}

} // namespace

ircmsg parse_irc_message(char* msg)
{
    parser p {msg};
    ircmsg out;

    /* MESSAGE TAGS */
    if (p.match('@')) {
        out.tags = parse_tags(p.word());
    }

    /* MESSAGE SOURCE */
    if (p.match(':')) {
        out.source = p.word();
    }

    /* MESSAGE COMMANDS */
    out.command = p.word();

    /* MESSAGE ARGUMENTS */
    while (!p.isempty()) {
        if (p.match(':')) {
            out.args.push_back(p.take());
            break;
        }
        out.args.push_back(p.word());
    }

    return out;
}
