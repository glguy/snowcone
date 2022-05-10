#pragma once

#include <string_view>
#include <vector>

struct irctag
{
    std::string_view key;
    std::string_view val;

    irctag(std::string_view key, std::string_view val) : key(key), val(val) {}
    
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
        std::vector<irctag> tags,
        std::string_view source,
        std::string_view command,
        std::vector<std::string_view> args)
    : tags(std::move(tags)),
      args(std::move(args)),
      command(command),
      source(source) {}

      friend bool operator==(ircmsg const&, ircmsg const&) = default;
};

struct irc_parse_error : public std::exception {
    int code;
    irc_parse_error(int code) : code(code) {}
};

/**
 * Parses the given IRC message into a structured format.
 * The original message is mangled to store string fragments
 * that are pointed to by the structured message type.
 * 
 * Returns zero for success, non-zero for parse error.
 */
ircmsg parse_irc_message(char* msg);
