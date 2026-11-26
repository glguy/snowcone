#pragma once
/**
 * @file ircmsg.hpp
 * @brief In-place parser for IRC protocol lines and IRCv3 message tags
 *
 * Parsed results hold string_views into the caller's buffer, which the
 * parser modifies; they are valid only while that buffer is alive and
 * unchanged.
 */

#include <exception>
#include <iosfwd>
#include <string_view>
#include <vector>

/// @brief One IRCv3 message tag; views into the parsed buffer
///
/// The key is not unescaped. The value is unescaped and is empty both for
/// "key" and for "key=".
struct irctag
{
    std::string_view key;
    std::string_view val;

    /// @brief Compare key and value contents (not addresses)
    friend auto operator==(irctag const&, irctag const&) -> bool = default;
};

/// @brief A parsed IRC message; every view points into the parsed buffer
///
/// source is empty when the message has none; args includes the trailing
/// (':'-prefixed) argument, without its colon, as its last element.
struct ircmsg
{
    std::vector<irctag> tags;
    std::string_view source;
    std::string_view command;
    std::vector<std::string_view> args;

    /// @brief Compare all fields by content, tags and args in order
    friend bool operator==(ircmsg const&, ircmsg const&) = default;
};

/// @brief Reason a parse failed
enum class irc_error_code {
    MISSING_TAG,     ///< a tag has an empty key (includes empty tag list, "@;", trailing ';')
    MISSING_COMMAND, ///< no command word after the tags and source
};

/// @brief Static human-readable message for code (e.g. "irc parse error:
/// missing tag"); never null
auto irc_error_message(irc_error_code code) noexcept -> char const*;

/// @brief Write the error code's message, as irc_error_message gives it
auto operator<<(std::ostream& out, irc_error_code) -> std::ostream&;

/// @brief Exception thrown by the parsers on malformed input
struct irc_parse_error final : public std::exception {
    irc_error_code code;

    /// @brief Construct an error carrying the given reason
    explicit irc_parse_error(irc_error_code code) : code(code) {}

    /// @brief The code's message, from irc_error_message
    auto what() const noexcept -> char const* override
    {
        return irc_error_message(code);
    }
};

/**
 * @brief Parse an IRC message in place
 *
 * Parses the given IRC message into a structured format.
 * The original message buffer is mangled to store string fragments
 * that are pointed to by the structured message type, so the result
 * is only valid while the buffer lives.
 *
 * Spaces separate fields and runs of them are collapsed; leading and
 * trailing spaces are ignored except inside the trailing argument.
 * The line must not include its CR LF terminator: it would become part
 * of the last field.
 *
 * @param msg null-terminated character buffer with raw IRC message
 *            (a nullptr is treated as an empty message).
 * @return parsed IRC message
 * @throw irc_parse_error MISSING_TAG for a malformed tag section (see
 *        parse_irc_tags) or MISSING_COMMAND when there is no command
 */
auto parse_irc_message(char* msg) -> ircmsg;

/**
 * @brief Parse an IRC tags string in place
 *
 * Parses the given IRC tags into a structured format.
 * The original message buffer is mangled to store string fragments
 * that are pointed to by the structured message type, so the result
 * is only valid while the buffer lives.
 *
 * The input is the ';'-separated tag list without its leading '@'.
 * Values are unescaped; keys are not. Duplicate keys are all kept, in order.
 *
 * @param msg null-terminated, writable character buffer with raw IRC
 *            tags. It must be a valid pointer: nullptr, like any other
 *            invalid pointer, is undefined behavior.
 * @return parsed IRC tags vector, in input order
 * @throw irc_parse_error MISSING_TAG when any tag has an empty key, which
 *        includes an empty input and a trailing ';'
 */
auto parse_irc_tags(char* msg) -> std::vector<irctag>;
