add_library(mysaslprep STATIC mysaslprep.c)
target_include_directories(mysaslprep PUBLIC include)
target_link_libraries(mysaslprep PkgConfig::LIBIDN PkgConfig::LUA)
