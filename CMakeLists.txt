cmake_minimum_required (VERSION 3.13)
set(CMAKE_C_STANDARD 11)

project(snowcone)

set(CURSES_NEED_WIDE TRUE)
find_package(Curses REQUIRED)
find_package(Lua 5.3 REQUIRED)

add_executable(snowcone main.c app.c buffer.c lua-ncurses.c)
target_link_libraries(snowcone PRIVATE uv dl ${LUA_LIBRARIES} ${CURSES_LIBRARIES})
target_include_directories(snowcone PRIVATE ${LUA_INCLUDE_DIR} ${CURSES_INCLUDE_PATH})
target_compile_options(snowcone PRIVATE ${CURSES_CFLAGS})

install (TARGETS snowcone DESTINATION bin)
