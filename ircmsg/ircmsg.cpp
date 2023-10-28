#include <cstring>
#include <optional>

#include "ircmsg.hpp"

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

std::string_view unescape_tag_value(char* const val)
{
    // only start copying at the first escape character
    // skip everything before that
    auto cursor = strchr(val, '\\');
    if (cursor == nullptr) { return {val}; }

    auto write = cursor;
    for (; *cursor; cursor++)
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
                case '\0': return {val, write};
            }
        }
        else
        {
            *write++ = *cursor;
        }
    }
    return {val, write};
}

} // namespace

auto parse_irc_tags(char* str) -> std::vector<irctag>
{
    std::vector<irctag> tags;

    do {
        auto val = strsep(&str, ";");
        auto key = strsep(&val, "=");
        if ('\0' == *key) {
            throw irc_parse_error(irc_error_code::MISSING_TAG);
        }
        if (nullptr == val) {
            tags.emplace_back(key, "");
        } else {
            tags.emplace_back(std::string_view{key, val-1}, unescape_tag_value(val));
        }
    } while(nullptr != str);

    return tags;
}

auto parse_irc_message(char* msg) -> ircmsg
{
    parser p {msg};
    ircmsg out;

    /* MESSAGE TAGS */
    if (p.match('@')) {
        out.tags = parse_irc_tags(p.word());
    }

    /* MESSAGE SOURCE */
    if (p.match(':')) {
        out.source = p.word();
    }

    /* MESSAGE COMMANDS */
    out.command = p.word();
    if (out.command.empty()) {
        throw irc_parse_error{irc_error_code::MISSING_COMMAND};
    }

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

auto ircmsg::hassource() const -> bool
{
    return source.data() != nullptr;
}

auto operator<<(std::ostream& out, irc_error_code code) -> std::ostream&
{
    switch(code) {
        case irc_error_code::MISSING_COMMAND: out << "MISSING COMMAND"; return out;
        case irc_error_code::MISSING_TAG: out << "MISSING TAG"; return out;
        default: return out;
    }
}
