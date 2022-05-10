/**
 * @file irc.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief IRC connection logic
 * 
 */

#pragma once

#include "app.hpp"

/**
 * @brief Starts the connection for the app
 * 
 * @return int 0 on success, 1 on failure
 */
int start_irc(app*);
