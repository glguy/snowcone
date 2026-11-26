/**
 * @file parse_toml.hpp
 * @brief The Lua function that turns TOML text into Lua tables
 *
 */
#pragma once

struct lua_State;

namespace mytoml {
/// parse_toml(text): parse text as a TOML 1.1 document. Returns the root
/// table, or nil and a message naming the positions of at most five
/// problems. Arrays become sequences, tables string-keyed tables, and
/// booleans, integers, floats and strings the matching Lua values (an empty
/// array and an empty table are both {}). Dates and times are rejected.
/// Raises an error only when text is not a string or number.
auto l_parse_toml(lua_State*) -> int;
}
