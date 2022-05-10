pkg_search_module(CHECK IMPORTED_TARGET check>=0.11.0)

find_package(GTest)

if (GTest_FOUND)
add_executable(tests-ircmsg tests-ircmsg.cpp)
target_link_libraries(tests-ircmsg PRIVATE ircmsg GTest::gtest_main)
add_test(NAME tests-ircmsg COMMAND tests-ircmsg)
endif()

if (CHECK_FOUND)
add_executable(tests-base64 tests-base64.c)
target_link_libraries(tests-base64 PRIVATE mybase64 PkgConfig::CHECK)
add_test(NAME tests-base64 COMMAND tests-base64)
endif()

find_program(LUACHECK luacheck)
if(NOT ${LUACHECK} EQUAL "LUACHECK-NOTFOUND")
message("luacheck was " ${LUACHECK})
add_test(NAME luacheck
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}/lua"
  COMMAND ${LUACHECK} ".")
endif()
