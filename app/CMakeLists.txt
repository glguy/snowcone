add_executable(snowcone
    main.c app.c socat.c buffer.c configuration.c
    irc.c tcp-server.c write.c read-line.c)
target_link_libraries(snowcone PRIVATE PkgConfig::UV PkgConfig::NCURSESW PkgConfig::LUA ircmsg mygeoip myncurses)

install(TARGETS snowcone DESTINATION bin)
add_definitions(-DINSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}")