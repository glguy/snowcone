#pragma once

#include <iostream>
#include <string_view>
#include <vector>

struct irctag
{
    std::string_view key;
    std::string_view val;

    irctag(std::string_view key, std::string_view val = {}) : key{key}, val{val} {}

    /// @brief Check if a tag has an associated value to distinguish between empty value and missing value.
    /// @return true when tag has an explicit value
    bool hasval() const;

    friend bool operator==(irctag const&, irctag const&) = default;
};

struct ircmsg
{
    std::vector<irctag> tags;
    std::vector<std::string_view> args;
    std::string_view source;
    std::string_view command;

    ircmsg() : tags(), args(), source(), command() {}

    ircmsg(
        std::vector<irctag> && tags,
        std::string_view source,
        std::string_view command,
        std::vector<std::string_view> && args)
    : tags(std::move(tags)),
      args(std::move(args)),
      command{command},
      source{source} {}

      bool hassource() const;

      friend bool operator==(ircmsg const&, ircmsg const&) = default;
};

enum class irc_error_code {
    MISSING_TAG,
    MISSING_COMMAND,
};

std::ostream& operator<<(std::ostream& out, irc_error_code);

struct irc_parse_error : public std::exception {
    irc_error_code code;
    irc_parse_error(irc_error_code code) : code(code) {}
};

/**
 * Parses the given IRC message into a structured format.
 * The original message is mangled to store string fragments
 * that are pointed to by the structured message type.
 *
 * Returns zero for success, non-zero for parse error.
 */
ircmsg parse_irc_message(char* msg);
