set(CURSES_NEED_WIDE TRUE)
find_package(Curses REQUIRED)

include(FindPkgConfig)
pkg_search_module(LUA REQUIRED lua>=5.3 lua5.3 lua-5.3 lua53 lua5.4 lua-5.4 lua54)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBUV REQUIRED IMPORTED_TARGET libuv)

add_executable(snowcone
    main.c app.c tls-helper.c buffer.c configuration.c mygeoip.c
    ircmsg.c lua-ncurses.c irc.c tcp-server.c mrs.c write.c read-line.c)
target_link_libraries(snowcone PRIVATE GeoIP PkgConfig::LIBUV ${LUA_LIBRARIES} ${CURSES_LIBRARIES})
target_include_directories(snowcone PRIVATE ${LUA_INCLUDE_DIR} ${CURSES_INCLUDE_PATH})
target_compile_options(snowcone PRIVATE ${CURSES_CFLAGS})

install(TARGETS snowcone DESTINATION bin)
