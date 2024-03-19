add_library(myopenssl STATIC myopenssl.cpp digest.cpp pkey.cpp errors.cpp bignum.cpp)
target_include_directories(myopenssl PUBLIC include)
target_link_libraries(myopenssl PUBLIC OpenSSL::Crypto PkgConfig::LUA)

add_library(myopenssl_shared SHARED myopenssl.cpp digest.cpp pkey.cpp errors.cpp bignum.cpp)
set_target_properties(myopenssl_shared PROPERTIES OUTPUT_NAME "myopenssl" PREFIX "" SUFFIX ".so")
target_include_directories(myopenssl_shared PUBLIC include)
target_link_libraries(myopenssl_shared PUBLIC OpenSSL::Crypto PkgConfig::LUA)

add_test(
    NAME TestMyopenssl
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMAND lua5.4 test/test.lua)
set_property(
    TEST TestMyopenssl
    PROPERTY ENVIRONMENT LUA_CPATH=${CMAKE_CURRENT_BINARY_DIR}/?.so)
