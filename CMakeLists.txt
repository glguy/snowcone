cmake_minimum_required (VERSION 3.13)
set(CMAKE_C_STANDARD 11)

project(snowcone)

set(CURSES_NEED_WIDE TRUE)
find_package(Curses REQUIRED)

add_executable(snowcone main.c app.c buffer.c lua-ncurses.c)
target_link_libraries(snowcone PRIVATE lua5.3 uv dl ${CURSES_LIBRARIES})
target_include_directories(snowcone PRIVATE ${CURSES_INCLUDE_PATH})
target_compile_options(snowcone PRIVATE ${CURSES_CFLAGS})

install (TARGETS snowcone DESTINATION bin)
