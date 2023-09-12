inc = include_directories('include')

libmyopenssl = static_library('myopenssl',
    ['pkey.cpp', 'digest.cpp', 'myopenssl.cpp'],
    include_directories: inc,
    dependencies: [liblua, libssl],
)

myopenssl = declare_dependency(
    include_directories: inc,
    dependencies: [liblua, libssl],
    link_with: [libmyopenssl]
)
