add_library(myopenssl STATIC myopenssl.cpp digest.cpp pkey.cpp errors.cpp)
target_include_directories(myopenssl PUBLIC include)
target_link_libraries(myopenssl PUBLIC OpenSSL::Crypto PkgConfig::LUA)
