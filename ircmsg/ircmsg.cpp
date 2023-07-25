#include <cstring>

#include "ircmsg.hpp"

#include <string_view>
#include <vector>

namespace {
class parser {
    char* msg_;
    inline static char empty[1];

    inline void trim() {
        while (*msg_ == ' ') msg_++;
    }

public:
    parser(char* msg) : msg_(msg) {
        if (msg_ == nullptr) {
            msg_ = empty;
        } else {
            trim();
        }
    }

    char* word() {
        auto const start = msg_;
        while (*msg_ != '\0' && *msg_ != ' ') msg_++;
        if (start == msg_) {
            throw irc_parse_error(6);
        }
        if (*msg_ != '\0') { // prepare for next token
            *msg_++ = '\0';
            trim();
        }
        return start;
    }

    bool match(char c) {
        if (c == *msg_) {
            msg_++;
            return true;
        }
        return false;
    }

    bool isempty() const {
        return *msg_ == '\0';
    }

    char const* peek() {
        return msg_;
    }
};

void unescape_tag_value(char *val)
{
    // only start copying at the first escape character
    // skip everything before that
    val = strchr(val, '\\');
    if (val == nullptr) { return; }

    char *write = val;
    for (char *cursor = val; *cursor; cursor++)
    {
        if (*cursor == '\\')
        {
            cursor++;
            switch (*cursor)
            {
                default  : *write++ = *cursor; break;
                case ':' : *write++ = ';'    ; break;
                case 's' : *write++ = ' '    ; break;
                case 'r' : *write++ = '\r'   ; break;
                case 'n' : *write++ = '\n'   ; break;
                case '\0': *write   = '\0'   ; return;
            }
        }
        else
        {
            *write++ = *cursor;
        }
    }
    *write = '\0';
}

std::vector<irctag> parse_tags(char* str)
{
    std::vector<irctag> tags;

    do {
        auto val = strsep(&str, ";");
        auto key = strsep(&val, "=");
        if ('\0' == *key) {
            throw irc_parse_error(1);
        }
        if (nullptr == val) {
            tags.emplace_back(key);
        } else {
            unescape_tag_value(val);
            tags.emplace_back(key, val);
        }
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
            out.args.push_back(p.peek());
            break;
        }
        out.args.push_back(p.word());
    }

    return out;
}
