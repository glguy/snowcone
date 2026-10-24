find_package(GTest 1.11)

if (GTest_DIR)
add_executable(tests-ircmsg tests-ircmsg.cpp)
target_link_libraries(tests-ircmsg PRIVATE ircmsg GTest::gtest_main)
gtest_discover_tests(tests-ircmsg)

add_executable(tests-base64 tests-base64.cpp)
target_link_libraries(tests-base64 PRIVATE mybase64 GTest::gmock GTest::gtest_main)
gtest_discover_tests(tests-base64)

add_executable(tests-connection
  tests-connection.cpp
  ../client/net/connection.cpp
  ../client/net/happy_eyeballs.cpp
  ../client/net/httpconnect.cpp
  ../client/net/socks5.cpp
  ../client/net/stream.cpp)
target_include_directories(tests-connection PRIVATE "${PROJECT_SOURCE_DIR}/client/net")
target_link_libraries(tests-connection PRIVATE ${BOOST_TARGETS} base64 OpenSSL::SSL GTest::gtest_main)
gtest_discover_tests(tests-connection)

# Drives client/irc/lua.cpp with real Lua against a local TCP server.
# The OpenSSL Lua bindings and ncurses-dependent pieces are replaced by stubs
# in the test itself, so only their headers are needed.
add_executable(tests-session
  tests-session.cpp
  ../client/irc/lua.cpp
  ../client/net/connection.cpp
  ../client/net/happy_eyeballs.cpp
  ../client/net/httpconnect.cpp
  ../client/net/linebuffer.cpp
  ../client/net/socks5.cpp
  ../client/net/stream.cpp)
target_include_directories(tests-session PRIVATE
  "${PROJECT_SOURCE_DIR}/client"
  "${PROJECT_SOURCE_DIR}/client/net"
  "${PROJECT_SOURCE_DIR}/myopenssl/include")
target_link_libraries(tests-session PRIVATE PkgConfig::LUA ircmsg ${BOOST_TARGETS} base64 OpenSSL::SSL)
add_test(NAME tests-session COMMAND tests-session)

endif()

find_program(LUACHECK luacheck)
if(NOT ${LUACHECK} STREQUAL "LUACHECK-NOTFOUND")
message("luacheck was " ${LUACHECK})
add_test(NAME luacheck-ircc
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}/ircc"
  COMMAND ${LUACHECK} ".")
add_test(NAME luacheck-dashboard
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}/dashboard"
  COMMAND ${LUACHECK} ".")
endif()
