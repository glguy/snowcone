#pragma once

#include <boost/asio/basic_socket.hpp>
#include <boost/system/error_code.hpp>

#include <cerrno>

#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

/**
 * @brief Open a socket that is close-on-exec from the moment it exists.
 *
 * Setting FD_CLOEXEC after the fact leaves a window (for a connecting socket,
 * the whole connect) in which a fork+exec elsewhere in the process would
 * inherit the descriptor. Where the platform supports SOCK_CLOEXEC the
 * descriptor is created with it; elsewhere (macOS) the flag is set
 * immediately after Asio opens the socket, which narrows but cannot
 * eliminate the window.
 *
 * @param socket Unopened socket to open
 * @param protocol Protocol to open the socket with
 * @param ec Set on failure; the socket is left closed
 */
template <typename Protocol, typename Executor>
auto open_cloexec(
    boost::asio::basic_socket<Protocol, Executor>& socket,
    Protocol const& protocol,
    boost::system::error_code& ec
) -> void
{
    ec.clear();

#ifdef SOCK_CLOEXEC
    int const fd = ::socket(protocol.family(), protocol.type() | SOCK_CLOEXEC, protocol.protocol());
    if (fd == -1)
    {
        ec.assign(errno, boost::system::system_category());
        return;
    }

    socket.assign(protocol, fd, ec);
    if (ec)
    {
        ::close(fd);
    }
#else
    socket.open(protocol, ec);
    if (ec)
    {
        return;
    }

    int const fd = socket.native_handle();
    int const flags = ::fcntl(fd, F_GETFD);
    if (flags == -1 || ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1)
    {
        int const error = errno;
        boost::system::error_code ignored;
        socket.close(ignored);
        ec.assign(error, boost::system::system_category());
    }
#endif
}
