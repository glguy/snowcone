// What write_escaped lets through to a terminal, and what it escapes

#include "strings.hpp"

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>

namespace {

auto escaped(std::string_view const input) -> std::string
{
    char* buffer = nullptr;
    std::size_t size = 0;
    auto const out = open_memstream(&buffer, &size);
    write_escaped(out, input);
    std::fclose(out);
    std::string result{buffer, size};
    std::free(buffer);
    return result;
}

TEST(WriteEscaped, PassesTextAndValidUtf8)
{
    for (auto const text : {"plain text", "tab\tand newline\n", "é€\U0001f600", " ", "\U0010ffff"})
    {
        EXPECT_EQ(text, escaped(text));
    }
}

TEST(WriteEscaped, EscapesControls)
{
    EXPECT_EQ("\\x1b[31m", escaped("\x1b[31m"));
    EXPECT_EQ("\\x0d\\x7f", escaped("\r\x7f"));
    // C1 controls, CSI among them
    EXPECT_EQ("\\xc2\\x9b", escaped("\xc2\x9b"));
    EXPECT_EQ("\\xc2\\x80", escaped("\xc2\x80"));
}

TEST(WriteEscaped, EscapesInvalidUtf8)
{
    // overlong forms of CSI (U+009B), which a lenient decoder would obey
    EXPECT_EQ("\\xe0\\x82\\x9b", escaped("\xe0\x82\x9b"));
    EXPECT_EQ("\\xf0\\x80\\x82\\x9b", escaped("\xf0\x80\x82\x9b"));
    EXPECT_EQ("\\xc1\\x9b", escaped("\xc1\x9b"));
    // a surrogate, and past U+10FFFF
    EXPECT_EQ("\\xed\\xa0\\x80", escaped("\xed\xa0\x80"));
    EXPECT_EQ("\\xf4\\x90\\x80\\x80", escaped("\xf4\x90\x80\x80"));
    // cut short, and a stray continuation byte
    EXPECT_EQ("\\xe2\\x82", escaped("\xe2\x82"));
    EXPECT_EQ("a\\x80b", escaped("a\x80" "b"));
}

} // namespace
