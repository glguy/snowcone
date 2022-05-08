# set(CMAKE_CXX_CLANG_TIDY /usr/local/opt/llvm/bin/clang-tidy -checks=-*,readability-*)
add_executable(snowcone
    main.cpp app.cpp applib.cpp socat.cpp configuration.cpp
    irc.cpp write.cpp read-line.cpp uv.cpp
    lua_uv_timer.cpp lua_uv_filewatcher.cpp lua_uv_dnslookup.cpp
    safecall.cpp)

target_link_libraries(snowcone PRIVATE
    PkgConfig::UV PkgConfig::NCURSESW PkgConfig::LUA
    ircmsg myncurses mybase64)

if(GEOIP_FOUND)
target_link_libraries(snowcone PRIVATE mygeoip)
endif()

configure_file(config.hpp.in config.hpp @ONLY)
target_include_directories(snowcone PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" include)

install(TARGETS snowcone DESTINATION "${CMAKE_INSTALL_BINDIR}")
