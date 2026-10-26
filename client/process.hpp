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
 * execute(command, args, callback [, options]) --> handle
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
 * - `options` (optional table, read with raw access; unknown keys raise):
 *     - `input` (string): Data written to the process's stdin, which is
 *       then closed. Without `input`, the child inherits snowcone's stdin,
 *       normally the terminal, so an interactive command can read from it
 *       while the UI is suspended.
 *     - `group` (boolean): Start the child in its own process group, so
 *       cancel() kills its descendants too. Requires `input`, since a
 *       child outside the foreground group is stopped if it reads the
 *       terminal.
 *     - `max_output` (integer): The most bytes accepted on each of stdout
 *       and stderr, 16 MiB by default. Past it the child is killed and the
 *       callback gets an error.
 *
 * The process runs asynchronously. The callback runs only after the
 * process has exited and both stdout and stderr have reached end of file.
 * A bad argument raises a Lua error, and the callback is not called.
 *
 * `handle:cancel()` drops the callback so it never runs, sends SIGKILL to
 * the child (its group, with `group`), and closes the pipes. It does
 * nothing once the callback has run. Collecting the handle doesn't stop
 * the process.
 */

struct lua_State;

/**
 * @brief Lua binding for asynchronous process execution.
 *
 * Lua function signature:
 *
 *     execute(command, args, callback [, options]) --> handle
 *
 * See file-level comment for details.
 *
 * @param L The Lua state.
 * @return int Always 1: the handle (results arrive through the callback).
 */
auto l_execute(lua_State* L) -> int;
