add_library(myopenssl STATIC myopenssl.cpp digest.cpp pkey.cpp errors.cpp bignum.cpp x509.cpp)
target_include_directories(myopenssl PUBLIC include)
target_link_libraries(myopenssl PUBLIC OpenSSL::Crypto PkgConfig::LUA)

# Runs in the client, which preloads myopenssl, so a sanitized build tests
# it sanitized too
if(BUILD_TESTING)
    add_test(
        NAME TestMyopenssl
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        COMMAND snowcone test/test.lua)
endif()
