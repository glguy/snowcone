#pragma once

#include <iostream>
#include <string_view>
#include <vector>

struct irctag
{
    std::string_view key;
    std::string_view val;

    irctag(std::string_view key, std::string_view val) : key{key}, val{val} {}

    friend auto operator==(irctag const&, irctag const&) -> bool = default;
};

struct ircmsg
{
    std::vector<irctag> tags;
    std::vector<std::string_view> args;
    std::string_view source;
    std::string_view command;

    ircmsg() = default;

    ircmsg(
        std::vector<irctag> && tags,
        std::string_view source,
        std::string_view command,
        std::vector<std::string_view> && args)
    : tags(std::move(tags)),
      args(std::move(args)),
      source{source},
      command{command} {}

      bool hassource() const;

      friend bool operator==(ircmsg const&, ircmsg const&) = default;
};

enum class irc_error_code {
    MISSING_TAG,
    MISSING_COMMAND,
};

auto operator<<(std::ostream& out, irc_error_code) -> std::ostream&;

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
auto parse_irc_message(char* msg) -> ircmsg;

auto parse_irc_tags(char* msg) -> std::vector<irctag>;
