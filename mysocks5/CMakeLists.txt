add_library(mysocks5 STATIC socks5.cpp httpconnect.cpp)
target_include_directories(mysocks5 PUBLIC include)
target_link_libraries(mysocks5 PUBLIC ${BOOST_TARGETS} base64)
