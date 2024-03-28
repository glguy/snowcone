#include <cstring>
#include <optional>

#include "ircmsg.hpp"

namespace {
class parser {
    /// @brief Remaining unparsed string
    char* msg_;

    /// @brief Sentinel used for parsers constructed with nullptr
    inline static char empty[1];

    /// @brief Drop leading spaces
    inline void trim() {
        while (*msg_ == ' ') msg_++;
    }

public:
    /// @brief Construct new parser from a mutable borrow of a null-terminated string
    parser(char* const msg) : msg_{msg} {
        if (msg_ == nullptr) {
            msg_ = empty;
        } else {
            trim();
        }
    }

    parser(parser const&) = delete;
    auto operator=(parser const&) -> parser& = delete;

    /// @brief Consume and return the next space-separated token
    /// @return Null-terminated string
    char* word() {
        auto const start = msg_;
        while (*msg_ != '\0' && *msg_ != ' ') msg_++;
        if (*msg_ != '\0') { // prepare for next token
            *msg_++ = '\0'; // replace space with terminator
            trim();
        }
        return start;
    }

    /// @brief Match and consume specified character
    /// @param c Character to match
    /// @return true if consumed and false if not
    bool match(char const c) {
        if (c == *msg_) {
            msg_++;
            return true;
        }
        return false;
    }

    /// @brief Predicate for empty string parse target
    /// @return true if empty and false otherwise
    bool isempty() const {
        return *msg_ == '\0';
    }

    /// @brief Return remaining unparsed string
    /// @return Null-terminated string
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
        auto const key = strsep(&val, "=");
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

auto parse_irc_message(char* const msg) -> ircmsg
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

auto operator<<(std::ostream& out, irc_error_code const code) -> std::ostream&
{
    switch(code) {
        case irc_error_code::MISSING_COMMAND: out << "MISSING COMMAND"; return out;
        case irc_error_code::MISSING_TAG: out << "MISSING TAG"; return out;
        default: return out;
    }
}
