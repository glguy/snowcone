#pragma once

#include <vector>

struct tag
{
    char const* key;
    char const* val;

    tag(char const* key, char const* val) : key(key), val(val) {}
};

struct ircmsg
{
    std::vector<tag> tags;
    std::vector<char const*> args;
    char const* source;
    char const* command;

    ircmsg() : tags(), args(), source(), command() {}

    ircmsg(
        std::vector<tag> tags,
        char const* source,
        char const* command,
        std::vector<char const*> args)
    : tags(std::move(tags)),
      args(std::move(args)),
      command(command),
      source(source) {}
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
