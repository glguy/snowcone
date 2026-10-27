# Compiled once, position-independent, for the client and for the Lua
# module the tests load into a stand-alone interpreter
add_library(myopenssl_objects OBJECT
    myopenssl.cpp digest.cpp pkey.cpp errors.cpp bignum.cpp x509.cpp)
set_target_properties(myopenssl_objects PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(myopenssl_objects PUBLIC include)
target_link_libraries(myopenssl_objects PUBLIC OpenSSL::Crypto PkgConfig::LUA)

add_library(myopenssl STATIC)
target_link_libraries(myopenssl PUBLIC myopenssl_objects)

if(BUILD_TESTING AND LUA_INTERPRETER)
    add_library(myopenssl_module MODULE)
    set_target_properties(myopenssl_module PROPERTIES OUTPUT_NAME "myopenssl" PREFIX "" SUFFIX ".so")
    target_link_libraries(myopenssl_module PRIVATE myopenssl_objects)
    add_test(
        NAME TestMyopenssl
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        COMMAND ${LUA_INTERPRETER} test/test.lua)
    set_property(
        TEST TestMyopenssl
        PROPERTY ENVIRONMENT LUA_CPATH=$<TARGET_FILE_DIR:myopenssl_module>/?.so)
elseif(BUILD_TESTING)
    message(STATUS "No lua${SNOWCONE_LUA_ABI} interpreter found; skipping TestMyopenssl")
endif()
