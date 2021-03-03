cmake_minimum_required (VERSION 3.13)
set(CMAKE_C_STANDARD 11)

project(snotecon)

set(CURSES_NEED_WIDE TRUE)
find_package(Curses REQUIRED)

add_executable(snote_con main.c app.c buffer.c lua-ncurses.c)
target_link_libraries(snote_con PRIVATE lua5.3 uv dl ${NCURSES_LIBRARIES})
target_include_directories(snote_con PRIVATE ${NCURSES_INCLUDE_PATH})
target_compile_options(snote_con PRIVATE ${NCURSES_CFLAGS})
