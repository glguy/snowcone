#include <base64.hpp>

#include <gtest/gtest.h>
#include <gmock/gmock.h>

#include <cstddef>
#include <cstring>
#include <limits>
#include <string_view>

namespace {

auto decode_string_view(std::string_view const input, char * const output) -> std::string_view
{
    auto const last = base64::decode(input, output);
    return last ? std::string_view{output, last} : std::string_view{};
}

TEST(Base64, EncodeFoobar)
{
    char buffer[9];

    base64::encode("", buffer);
    EXPECT_STREQ(buffer, "");

    base64::encode("f", buffer);
    EXPECT_STREQ(buffer, "Zg==");

    base64::encode("fo", buffer);
    EXPECT_STREQ(buffer, "Zm8=");

    base64::encode("foo", buffer);
    EXPECT_STREQ(buffer, "Zm9v");

    base64::encode("foob", buffer);
    EXPECT_STREQ(buffer, "Zm9vYg==");

    base64::encode("fooba", buffer);
    EXPECT_STREQ(buffer, "Zm9vYmE=");

    base64::encode("foobar", buffer);
    EXPECT_STREQ(buffer, "Zm9vYmFy");
}


TEST(Base64, DecodeFoobar)
{
    char buffer[6];

    ASSERT_EQ(decode_string_view("", buffer), "");
    ASSERT_EQ(decode_string_view("Zg==", buffer), "f");
    ASSERT_EQ(decode_string_view("Zm8=", buffer), "fo");
    ASSERT_EQ(decode_string_view("Zm9v", buffer), "foo");
    ASSERT_EQ(decode_string_view("Zm9vYg==", buffer), "foob");
    ASSERT_EQ(decode_string_view("Zm9vYmE=", buffer), "fooba");
    ASSERT_EQ(decode_string_view("Zm9vYmFy", buffer), "foobar");
}

TEST(Base64, Exhaust1)
{
    for (int i = std::numeric_limits<char>::min();
         i <= std::numeric_limits<char>::max();
         i++)
    {
        char input[1] {char(i)};
        char output64[5];
        char recovered[1];

        base64::encode({input, 1}, output64);
        ASSERT_EQ(base64::decode(output64, recovered), recovered+1);
        EXPECT_EQ(recovered[0], input[0]);
    }
}

TEST(Base64, Zeros) {
    char buffer[6];

    ASSERT_EQ(decode_string_view("AA==", buffer), std::string_view("\0", 1));
    ASSERT_EQ(decode_string_view("AAA=", buffer), std::string_view("\0\0", 2));
    ASSERT_EQ(decode_string_view("AAAA", buffer), std::string_view("\0\0\0", 3));
}

TEST(Base64, Ones) {
    uint32_t buffer = UINT32_C(0xffffffff);
    char output[9];

    base64::encode({reinterpret_cast<char*>(&buffer), sizeof(buffer)}, output);
    EXPECT_STREQ(output, "/////w==");

    uint32_t decoded {};
    ASSERT_EQ(base64::decode(output, reinterpret_cast<char*>(&decoded)), reinterpret_cast<char*>(&decoded) + 4);

    ASSERT_EQ(decoded, UINT32_C(0xffffffff));
}

TEST(Base64, Junk) {
    char buffer[6];

    char input[] = "AAAAAA";
    input[2] = -128;
    input[4] = 0;

    ASSERT_EQ(base64::decode({input, 6}, buffer), buffer + 3);
    EXPECT_EQ(std::string_view(buffer, buffer + 3), std::string_view("\0\0\0", 3));
}

} // namespace

int main(int argc, char **argv) {
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
