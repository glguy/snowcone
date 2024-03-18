add_library(mysocks5 STATIC socks5.cpp)
target_include_directories(mysocks5 PUBLIC include)
target_link_libraries(mysocks5 PUBLIC ${BOOST_TARGETS})
