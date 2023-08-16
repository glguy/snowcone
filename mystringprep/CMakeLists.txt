add_library(mystringprep STATIC mystringprep.c)
target_include_directories(mystringprep PUBLIC include)
target_link_libraries(mystringprep PkgConfig::LIBIDN PkgConfig::LUA)
