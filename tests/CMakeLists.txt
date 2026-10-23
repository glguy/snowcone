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
