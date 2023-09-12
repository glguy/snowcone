inc = include_directories('include')

libhsfilter = static_library('hsfilter',
    ['hsfilter.cpp'],
    include_directories: inc,
    dependencies: [liblua, libhs, mybase64],
)

hsfilter = declare_dependency(
    include_directories: inc,
    dependencies: [liblua, libhs],
    link_with: libhsfilter,
)
