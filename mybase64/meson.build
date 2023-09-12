inc = include_directories('include')
libmybase64 = static_library('mybase64',
    ['mybase64.cpp'],
    include_directories: inc,
)

mybase64 = declare_dependency(
    include_directories: inc,
    link_with: libmybase64,
)
