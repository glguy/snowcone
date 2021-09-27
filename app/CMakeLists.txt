include(FindPkgConfig)
find_package(Lua REQUIRED)
find_package(PkgConfig REQUIRED)

pkg_check_modules(UV       REQUIRED IMPORTED_TARGET libuv)
pkg_check_modules(NCURSESW REQUIRED IMPORTED_TARGET ncursesw)
pkg_check_modules(GEOIP    REQUIRED IMPORTED_TARGET geoip)

add_executable(snowcone
    main.c app.c socat.c buffer.c configuration.c mygeoip.c
    ircmsg.c lua-ncurses.c irc.c tcp-server.c mrs.c write.c read-line.c)
target_link_libraries(snowcone PRIVATE PkgConfig::UV PkgConfig::NCURSESW PkgConfig::GEOIP ${LUA_LIBRARIES})
target_include_directories(snowcone PRIVATE ${LUA_INCLUDE_DIR})

install(TARGETS snowcone DESTINATION bin)
