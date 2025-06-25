#include <ircmsg.hpp>

#include <gtest/gtest.h>

namespace {

TEST(Irc, NoArgs) {
  char input[] = "cmd";
  ircmsg expect {{}, {}, "cmd", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, NoArgsTrailing) {
  char input[] = "cmd ";
  ircmsg expect {{}, {}, "cmd", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, OneArg) {
  char input[] = "cmd arg";
  ircmsg expect {{}, {}, "cmd", {"arg"}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, CommandArgSpaced) {
  char input[] = "  cmd  arg  ";
  ircmsg expect {{}, {}, "cmd", {"arg"}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, CommandArgColon) {
  char input[] = "command arg :arg2";
  ircmsg expect {{}, {}, "command", {"arg", "arg2"}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, ColonArg) {
  char input[] = "command arg :arg2  more";
  ircmsg expect {{}, {}, "command", {"arg", "arg2  more"}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, InternalColon) {
  char input[] = "command arg:arg2";
  ircmsg expect {{}, {}, "command", {"arg:arg2"}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, MaxArgsColon)
{
  char input[] = "command 1 2 3 4 5 6 7 8 9 10 11 12 13 14 :15 16";
  ircmsg expect {{}, {}, "command", {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15 16"}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TestBarePrefix) {
  char input[] = ":prefix";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, BarePrefixSpace)
{
  char input[] = ":prefix ";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, Prefix)
{
  char input[] = ":prefix command arg :arg2 ";
  ircmsg expect {{}, "prefix", "command", {"arg", "arg2 "}};
  EXPECT_EQ(
    parse_irc_message(input),
    expect);
}

TEST(Irc, PrefixAndColon) {
  char input[] = ":prefix command arg :";
  ircmsg expect {{}, "prefix", "command", {"arg", ""}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, SimpleTag) {
  char input[] = "@key=val :prefix command arg :";
  ircmsg expect {{{"key", "val"}}, "prefix", "command", {"arg", ""}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TwoTags) {
  char input[] = "@key=val;yek=eulav :prefix command";
  ircmsg expect {{{"key","val"}, {"yek","eulav"}}, "prefix", "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, FirstTagNoValue) {
  char input[] = "@key;yek=eulav :prefix command";
  ircmsg expect {{{"key", {}}, {"yek", "eulav"}}, "prefix", "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagEscapes) {
  ircmsg expect {{{"key", {}}, {"yek", "; \\\r\n"}}, "prefix", "command", {}};
  char input[] = "@key;yek=\\:\\s\\\\\\r\\n :prefix command";
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, LoneTagNoValue) {
  char input[] = "@key= :pfx command";
  ircmsg expect {{{"key",""}}, "pfx", "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagTrailingBackslash) {
  char input[] = "@key=x\\ command";
  ircmsg expect {{{"key", "x"}}, {}, "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagBadEscape) {
  char input[] = "@key=\\x\\;yek command";
  ircmsg expect {{{"key","x"},{"yek", {}}}, {}, "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagKeyUnescaped) {
  char input[] = "@k\\s=x command";
  ircmsg expect {{{"k\\s", "x"}}, {}, "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TwoEmptyTagValues) {
  char input[] = "@key=;yek= command";
  ircmsg expect {{{"key", ""}, {"yek", ""}}, {}, "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagNoBody) {
  char input[] = "@ :pfx command";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, TagLoneSemi) {
  char input[] = "@; command";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, EmptyPrefix) {
  char input[] = ": command";
  ircmsg expect {{}, "", "command", {}};
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagNoKey) {
  char input[] = "@=value command";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, TagTrailingSemi) {
  char input[] = "@key=value; command";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, TagNoCommand) {
  char input[] = "@key=value";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, TagLoneSemiNoCommand) {
  char input[] = "@key=value;";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, Colon) {
  char input[] = ":";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, Empty) {
  char input[] = "";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, Spaces) {
  char input[] = "   ";
  EXPECT_ANY_THROW(parse_irc_message(input));
}

TEST(Irc, MixedValidAndUnconventionalTags) {
    char input[] = "@valid=correct;empty;noValue;strange=@;key\\with\\escapes=\\s\\:\\r\\n :prefix command arg1 :arg2 with space";
    ircmsg expected {
        {
            {"valid", "correct"},
            {"empty", ""},
            {"noValue", ""},
            {"strange", "@"},
            {"key\\with\\escapes", " ;\r\n"}
        },
        "prefix",
        "command",
        {"arg1", "arg2 with space"}
    };

    EXPECT_EQ(parse_irc_message(input), expected);
}

}

int main(int argc, char **argv) {
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
