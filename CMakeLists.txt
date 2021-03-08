cmake_minimum_required(VERSION 3.13)
set(CMAKE_C_STANDARD 11)

project(snowcone
    VERSION 1
    DESCRIPTION "IRC server notice console"
    HOMEPAGE_URL "https://github.com/glguy/snowcone"
    LANGUAGES C
)

set(CURSES_NEED_WIDE TRUE)
find_package(Curses REQUIRED)

find_package(Lua 5.3 REQUIRED)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBUV REQUIRED IMPORTED_TARGET libuv)

add_executable(snowcone main.c app.c buffer.c lua-ncurses.c)
target_link_libraries(snowcone PRIVATE PkgConfig::LIBUV ${LUA_LIBRARIES} ${CURSES_LIBRARIES})
target_include_directories(snowcone PRIVATE ${LUA_INCLUDE_DIR} ${CURSES_INCLUDE_PATH})
target_compile_options(snowcone PRIVATE ${CURSES_CFLAGS})

install(TARGETS snowcone DESTINATION bin)
install(DIRECTORY "lua" DESTINATION "share/snowcone")