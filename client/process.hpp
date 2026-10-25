#pragma once

/**
 * @file process.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Lua binding for asynchronous system process execution.
 *
 * This header declares the interface for exposing asynchronous process
 * execution to Lua scripts. The provided function, `l_execute`, is
 * exposed as `snowcone.execute`.
 *
 * ## Lua Interface
 *
 * ```lua
 * execute(command, args, callback [, input]) --> true
 * ```
 *
 * - `command` (string): The executable to run. A name without a directory
 *   is looked up in PATH.
 * - `args` (table): Array-style table of string arguments, read with raw
 *   access. Numbers are converted; any other value, including a hole,
 *   raises, so convert objects with tostring first.
 * - `callback` (any callable): Invoked once, on completion or error.
 *     - On success: `callback(exit_code, stdout, stderr)`
 *     - On failure: `callback(nil, error_message)`
 * - `input` (optional string): Data written to the process's stdin, which
 *   is then closed. Without `input`, the child inherits snowcone's stdin,
 *   normally the terminal, so an interactive command can read from it
 *   while the UI is suspended.
 *
 * The process runs asynchronously, and execute returns true once it has
 * been started. The callback runs only after the process has exited and
 * both stdout and stderr have reached end of file. A bad argument raises
 * a Lua error, and the callback is not called.
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
 * @return int Always 1: true (results arrive through the callback).
 */
auto l_execute(lua_State* L) -> int;
