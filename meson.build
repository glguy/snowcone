project('snowcone', 'c', 'cpp',
    version: '0.1',
    license: 'ISC',
    default_options : ['cpp_std=c++20', 'c_std=c17'])

liblua = dependency('lua', required: true, version: '>=5.4.0')
libssl = dependency('openssl', required: true, version: '>=3')
libncurses = dependency('ncurses', required: true, version: '>=6')
libboost = dependency('boost', required: true)
libidn = dependency('libidn')
libgeoip = dependency('geoip')
libhs = dependency('libhs')

subdir('myncurses')
subdir('myopenssl')
subdir('mybase64')
subdir('ircmsg')

if libgeoip.found()
subdir('mygeoip')
endif

if libidn.found()
subdir('mystringprep')
endif

# depends on base64
if libhs.found()
subdir('hsfilter')
endif

# depends on everything above
subdir('client')

install_subdir('ircc', install_dir: get_option('datadir') / 'snowcone')
install_subdir('dashboard', install_dir: get_option('datadir') / 'snowcone')
install_man('snowcone.1')
