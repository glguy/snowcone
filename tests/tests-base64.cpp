#include <mybase64.hpp>

#include <gtest/gtest.h>
#include <gmock/gmock.h>

#include <cstddef>
#include <limits>
#include <string_view>

namespace {

TEST(Base64, EncodeFoobar)
{
    char buffer[9];

    mybase64_encode("", 0, buffer);
    EXPECT_STREQ(buffer, "");

    mybase64_encode("f", 1, buffer);
    EXPECT_STREQ(buffer, "Zg==");

    mybase64_encode("fo", 2, buffer);
    EXPECT_STREQ(buffer, "Zm8=");

    mybase64_encode("foo", 3, buffer);
    EXPECT_STREQ(buffer, "Zm9v");

    mybase64_encode("foob", 4, buffer);
    EXPECT_STREQ(buffer, "Zm9vYg==");

    mybase64_encode("fooba", 5, buffer);
    EXPECT_STREQ(buffer, "Zm9vYmE=");

    mybase64_encode("foobar", 6, buffer);
    EXPECT_STREQ(buffer, "Zm9vYmFy");
}


TEST(Base64, DecodeFoobar)
{
    size_t len;
    char buffer[6];

    ASSERT_TRUE(mybase64_decode("", 0, buffer, &len));
    ASSERT_EQ(len, 0);

    ASSERT_TRUE(mybase64_decode("Zg==", 4, buffer, &len));
    ASSERT_EQ(len, 1);
    EXPECT_EQ(std::string_view(buffer, len), "f");

    ASSERT_TRUE(mybase64_decode("Zm8=", 4, buffer, &len));
    ASSERT_EQ(len, 2);
    EXPECT_EQ(std::string_view(buffer, len), "fo");

    ASSERT_TRUE(mybase64_decode("Zm9v", 4, buffer, &len));
    ASSERT_EQ(len, 3);
    EXPECT_EQ(std::string_view(buffer, len), "foo");

    ASSERT_TRUE(mybase64_decode("Zm9vYg==", 8, buffer, &len));
    ASSERT_EQ(len, 4);
    EXPECT_EQ(std::string_view(buffer, len), "foob");

    ASSERT_TRUE(mybase64_decode("Zm9vYmE=", 8, buffer, &len));
    ASSERT_EQ(len, 5);
    EXPECT_EQ(std::string_view(buffer, len), "fooba");

    ASSERT_TRUE(mybase64_decode("Zm9vYmFy", 8, buffer, &len));
    ASSERT_EQ(len, 6);
    EXPECT_EQ(std::string_view(buffer, len), "foobar");
}

TEST(Base64, Exhaust1)
{
    for (int i = std::numeric_limits<char>::min();
         i <= std::numeric_limits<char>::max();
         i++)
    {
        char input = i;
        char output64[5];
        char recovered;
        size_t len;

        mybase64_encode(&input, 1, output64);
        ASSERT_TRUE(mybase64_decode(output64, strlen(output64), &recovered, &len));
        EXPECT_EQ(len, 1);
        EXPECT_EQ(recovered, input);
    }
}

} // namespace

int main(int argc, char **argv) {
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
