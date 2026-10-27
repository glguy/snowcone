# set(CMAKE_CXX_CLANG_TIDY /usr/local/opt/llvm/bin/clang-tidy -checks=-*,readability-*)
# Connections: TCP with happy eyeballs, TLS, SOCKS5 and HTTP CONNECT
add_library(snowcone_net STATIC
    net/connection.cpp net/happy_eyeballs.cpp net/httpconnect.cpp
    net/linebuffer.cpp net/socks5.cpp net/stream.cpp)
target_include_directories(snowcone_net PUBLIC net)
target_link_libraries(snowcone_net PUBLIC ${BOOST_TARGETS} OpenSSL::SSL base64)

# Lua bindings for IRC sessions, processes and timers. They call into
# app.cpp, which tests-session replaces with stubs.
add_library(snowcone_bindings STATIC irc/lua.cpp process.cpp timer.cpp)
target_include_directories(snowcone_bindings PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(snowcone_bindings PUBLIC
    snowcone_net PkgConfig::LUA ircmsg myopenssl)

add_executable(snowcone
    main.cpp app.cpp applib.cpp bracketed_paste.cpp
    safecall.cpp dnslookup.cpp httpd.cpp
    )
target_link_libraries(snowcone PRIVATE
    snowcone_bindings
    PkgConfig::NCURSESW PkgConfig::LUA ${BOOST_TARGETS} OpenSSL::SSL
    ircmsg myncurses mybase64 myopenssl mytoml)
configure_file(config.hpp.in config.hpp @ONLY)
target_include_directories(snowcone PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")

if(LIBHS_FOUND)
target_link_libraries(snowcone PRIVATE hsfilter)
endif()

if(LIBIDN_FOUND)
target_link_libraries(snowcone PRIVATE mystringprep)
endif()

if (LIBARCHIVE_FOUND)
target_link_libraries(snowcone PRIVATE myarchive)
endif()

install(TARGETS snowcone DESTINATION "${CMAKE_INSTALL_BINDIR}")
