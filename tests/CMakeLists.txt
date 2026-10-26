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
# The real OpenSSL Lua bindings are linked; the ncurses-dependent pieces are
# replaced by stubs in the test itself.
add_executable(tests-session
  tests-session.cpp
  ../client/irc/lua.cpp
  ../client/net/connection.cpp
  ../client/net/happy_eyeballs.cpp
  ../client/net/httpconnect.cpp
  ../client/net/linebuffer.cpp
  ../client/net/socks5.cpp
  ../client/net/stream.cpp
  ../client/process.cpp
  ../client/timer.cpp)
target_include_directories(tests-session PRIVATE
  "${PROJECT_SOURCE_DIR}/client"
  "${PROJECT_SOURCE_DIR}/client/net")
target_link_libraries(tests-session PRIVATE PkgConfig::LUA ircmsg myopenssl ${BOOST_TARGETS} base64 OpenSSL::SSL)
add_test(NAME tests-session COMMAND tests-session)

endif()

# Lua tests run inside the real client, without a UI: snowcone exits once
# the test has no work left, and nonzero after any uncaught Lua error.
foreach(name test-dnslookup test-escape test-execute test-sasl test-scram test-schema test-strings)
  add_test(NAME ${name}
    COMMAND snowcone "${CMAKE_CURRENT_SOURCE_DIR}/${name}.lua")
  set_tests_properties(${name} PROPERTIES TIMEOUT 30)
endforeach()

# hub's tests share tests/hub/lib.lua and load hub from the source tree
foreach(name test-reload test-structure test-net test-ui test-snotice test-topology test-oper test-chat test-views test-plugins)
  add_test(NAME hub-${name}
    COMMAND snowcone "${CMAKE_CURRENT_SOURCE_DIR}/hub/${name}.lua")
  set_tests_properties(hub-${name} PROPERTIES TIMEOUT 30)
endforeach()

# Drives start_httpd with curl through snowcone.execute
find_program(CURL curl)
if(CURL)
  add_test(NAME script-httpd
    COMMAND snowcone "${CMAKE_CURRENT_SOURCE_DIR}/script-httpd.lua")
  # A failed check can leave a listener open, so the timeout ends the run
  set_tests_properties(script-httpd PROPERTIES TIMEOUT 60)
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
add_test(NAME luacheck-hub
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}/hub"
  COMMAND ${LUACHECK} ".")
endif()
