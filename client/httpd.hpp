#pragma once

extern "C" {
struct lua_State;

/**
 * @brief Lua binding: start_httpd(host, service, handler) --> listener
 *
 * Listens for HTTP/1.1 requests on host and service. Each request calls
 * handler(method, target, body, headers) and responds with its results
 * (status, body, headers):
 * - status: an integer from 100 to 999. Returning no status gives a 500.
 * - body: a string, or anything else for an empty body.
 * - headers: a table of string names to string values, or anything else for
 *   none. CR, LF and NUL are not allowed in either.
 *
 * Errors are reported as handler(nil, kind, message) and their results are
 * ignored. A handler error is reported with kind "handler" and a traceback,
 * and an invalid status or header with kind "handler" and what was wrong.
 * The client gets a generic 500 for both.
 *
 * The listener has close(), which also closes its open connections. It is
 * closed when collected.
 */
int start_httpd(lua_State*);
}
