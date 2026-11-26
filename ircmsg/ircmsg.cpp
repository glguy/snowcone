#include <cstring>
#include <optional>
#include <ostream>

#include "ircmsg.hpp"

namespace {
/// @brief Destructive tokenizer over a mutable null-terminated string
///
/// Tokens are terminated in place by overwriting the separating space.
class parser {
    /// @brief Remaining unparsed string
    char* msg_;

    /// @brief Sentinel used for parsers constructed with nullptr
    inline static char empty[1];

    /// @brief Advance past any spaces (only ' ') at the cursor
    inline void trim() {
        while (*msg_ == ' ') msg_++;
    }

public:
    /// @brief Construct new parser from a mutable borrow of a null-terminated string
    ///
    /// Leading spaces are skipped. A nullptr is treated as an empty string.
    parser(char* const msg) : msg_{msg} {
        if (msg_ == nullptr) {
            msg_ = empty;
        } else {
            trim();
        }
    }

    /// @brief Not copyable: copies would share and both mutate one buffer
    parser(parser const&) = delete;
    /// @brief Not copy-assignable; see the deleted copy constructor
    auto operator=(parser const&) -> parser& = delete;

    /// @brief Consume and return the next space-separated token
    ///
    /// Overwrites the following space with a terminator and skips any
    /// further spaces. At the cursor's end, or on a space, returns "".
    /// @return Null-terminated string inside the parsed buffer
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

    /// @brief Return remaining unparsed string without consuming it
    /// @return Null-terminated string inside the parsed buffer
    char const* peek() const {
        return msg_;
    }
};

/// @brief Construct a string_view of the tag after unescaping.
///
/// This performs the unescaping in-place and the returned
/// string_view uses the storage of the character pointer
/// passed in.
///
/// The tag escape format recognizes:
/// - "\\r": '\r'
/// - "\\n": '\n'
/// - "\\:": ';'
/// - "\\s": ' '
///
/// When any other escape sequence is used the leading '\\'
/// is just dropped (so "\\\\" gives '\\'), and a lone trailing '\\'
/// is dropped entirely. The unescaped value is never longer than the
/// input, so it is written over the input; bytes after it are left stale.
///
/// @param val The escaped, null-terminated value
/// @return The view of the processed value
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
            tags.emplace_back(key);
        } else {
            tags.emplace_back(key, unescape_tag_value(val));
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
            out.args.emplace_back(p.peek());
            break;
        }
        out.args.emplace_back(p.word());
    }

    return out;
}

auto irc_error_message(irc_error_code const code) noexcept -> char const*
{
    switch (code) {
    case irc_error_code::MISSING_TAG:
        return "irc parse error: missing tag";
    case irc_error_code::MISSING_COMMAND:
        return "irc parse error: missing command";
    default:
        return "irc parse error: unknown error";
    }
}

auto operator<<(std::ostream& out, irc_error_code const code) -> std::ostream&
{
    return out << irc_error_message(code);
}
