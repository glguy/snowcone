find_package(GTest 1.11)

if (GTest_FOUND EQUAL 1)
add_executable(tests-ircmsg tests-ircmsg.cpp)
target_link_libraries(tests-ircmsg PRIVATE ircmsg GTest::gtest_main)
gtest_discover_tests(tests-ircmsg)

add_executable(tests-base64 tests-base64.cpp)
target_link_libraries(tests-base64 PRIVATE mybase64 GTest::gmock GTest::gtest_main)
gtest_discover_tests(tests-base64)
endif()

find_program(LUACHECK luacheck)
if(NOT ${LUACHECK} EQUAL "LUACHECK-NOTFOUND")
message("luacheck was " ${LUACHECK})
add_test(NAME luacheck
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}/lua"
  COMMAND ${LUACHECK} ".")
endif()
