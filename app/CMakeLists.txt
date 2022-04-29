add_executable(snowcone
    main.cpp app.cpp socat.cpp configuration.cpp
    irc.cpp tcp-server.cpp write.cpp read-line.cpp
    lua_uv_timer.cpp lua_uv_filewatcher.cpp safecall.cpp)

target_link_libraries(snowcone PRIVATE
    PkgConfig::UV PkgConfig::NCURSESW PkgConfig::LUA
    ircmsg myncurses mybase64)

if(GEOIP_FOUND)
target_link_libraries(snowcone PRIVATE mygeoip)
endif()

configure_file(config.hpp.in config.hpp @ONLY)
target_include_directories(snowcone PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" include)

install(TARGETS snowcone DESTINATION "${CMAKE_INSTALL_BINDIR}")
