inc = include_directories('include')

libircmsg = static_library('ircmsg',
    ['ircmsg.cpp'],
    include_directories: inc,
)

ircmsg = declare_dependency(
    include_directories: inc,
    link_with: libircmsg
)
