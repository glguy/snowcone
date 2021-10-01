cmake_minimum_required(VERSION 3.13)
set(CMAKE_C_STANDARD 11)

project(snowcone
    VERSION 1
    DESCRIPTION "IRC server notice console"
    HOMEPAGE_URL "https://github.com/glguy/snowcone"
    LANGUAGES C
)

include(CTest)
find_package(PkgConfig REQUIRED)

add_subdirectory(ircmsg)
add_subdirectory(app)

if(BUILD_TESTING)
add_subdirectory(tests)
endif()

install(DIRECTORY "lua" DESTINATION "share/snowcone")
