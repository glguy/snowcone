#pragma once

#include <boost/system/system_error.hpp>

#include <stdexcept>
#include <string>

/**
 * @brief Explain an error to the user.
 *
 * Unlike error_code::what(), leaves out the category, the number and the
 * source location.
 */
auto describe_error(boost::system::error_code const& ec) -> std::string;

/**
 * @brief A failure whose what() is written for the user.
 *
 * The code stays available to callers that act on it.
 */
class connection_error final : public boost::system::system_error
{
    // An exception's copies must not throw, so this isn't a std::string
    std::runtime_error text_;

public:
    /// @param ec The underlying error, kept for code()
    /// @param text The complete message for what()
    connection_error(boost::system::error_code const& ec, std::string const& text)
        : system_error{ec}
        , text_{text}
    {
    }

    /// The user-facing text, not system_error's composed message
    auto what() const noexcept -> char const* override
    {
        return text_.what();
    }
};
