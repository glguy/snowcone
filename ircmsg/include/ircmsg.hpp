#pragma once

#include <iostream>
#include <string_view>
#include <vector>

struct irctag
{
    std::string_view key;
    std::string_view val;

    friend auto operator==(irctag const&, irctag const&) -> bool = default;
};

struct ircmsg
{
    std::vector<irctag> tags;
    std::string_view source;
    std::string_view command;
    std::vector<std::string_view> args;

    friend bool operator==(ircmsg const&, ircmsg const&) = default;
};

enum class irc_error_code {
    MISSING_TAG,
    MISSING_COMMAND,
};

auto operator<<(std::ostream& out, irc_error_code) -> std::ostream&;

struct irc_parse_error final : public std::exception {
    irc_error_code code;

    irc_parse_error(irc_error_code code) : code(code) {}

    auto what() const noexcept -> char const* override
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
};

/**
 * @brief Parse an IRC message in place
 *
 * Parses the given IRC message into a structured format.
 * The original message buffer is mangled to store string fragments
 * that are pointed to by the structured message type.
 *
 * @param msg null-terminated character buffer with raw IRC message.
 * @return parsed IRC message
 * @throw irc_parse_error on failure
 */
auto parse_irc_message(char* msg) -> ircmsg;

/**
 * @brief Parse an IRC tags string in place
 *
 * Parses the given IRC tags into a structured format.
 * The original message buffer is mangled to store string fragments
 * that are pointed to by the structured message type.
 *
 * @param msg null-terminated character buffer with raw IRC tags.
 * @return parsed IRC tags vector
 * @throw irc_parse_error on failure
 */
auto parse_irc_tags(char* msg) -> std::vector<irctag>;
