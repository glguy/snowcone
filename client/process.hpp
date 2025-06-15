#pragma once

/**
 * @file process.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Lua binding for asynchronous system process execution.
 *
 * This header declares the interface for exposing asynchronous process
 * execution to Lua scripts. The provided function, `l_execute`, is will
 * be exposed as `snowcone.execute`.
 *
 * ## Lua Interface
 *
 * ```lua
 * execute(command, args, callback [, input])
 * ```
 *
 * - `command` (string): The executable to run.
 * - `args` (table): Array-style table of string arguments.
 * - `callback` (function): Invoked on process completion or error.
 *     - On success: `callback(exit_code, stdout, stderr)`
 *     - On failure: `callback(nil, error_message)`
 * - `input` (optional string): Data to send to the process's stdin.
 *
 * The process runs asynchronously. The callback receives the exit code,
 * standard output, and standard error as strings, or an error message if
 * process launch or execution fails.
 */

struct lua_State;

/**
 * @brief Lua binding for asynchronous process execution.
 *
 * Lua function signature:
 *
 *     execute(command, args, callback [, input])
 *
 * See file-level comment for details.
 *
 * @param L The Lua state.
 * @return int Always returns 0 (async, results via callback).
 */
auto l_execute(lua_State* L) -> int;
