#include <ircmsg.hpp>

#include <gtest/gtest.h>

namespace {

TEST(Irc, NoArgs) {
  char input[] = "cmd";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "cmd", {}));
}

TEST(Irc, NoArgsTrailing) {
  char input[] = "cmd ";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "cmd", {})
  );
}

TEST(Irc, OneArg) {
  char input[] = "cmd arg";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "cmd", {"arg"}));
}

TEST(Irc, CommandArgSpaced) {
  char input[] = "  cmd  arg  ";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "cmd", {"arg"}));
}

TEST(Irc, CommandArgColon) {
  char input[] = "command arg :arg2";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "command", {"arg", "arg2"}));
}

TEST(Irc, ColonArg) {
  char input[] = "command arg :arg2  more";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "command", {"arg", "arg2  more"}));
}

TEST(Irc, InternalColon) {
  char input[] = "command arg:arg2";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "command", {"arg:arg2"}));
}

TEST(Irc, MaxArgsColon)
{
  char input[] = "command 1 2 3 4 5 6 7 8 9 10 11 12 13 14 :15 16";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, {}, "command", {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15 16"}));
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
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, "prefix", "command", {"arg", "arg2 "}));
}

TEST(Irc, PrefixAndColon) {
  char input[] = ":prefix command arg :";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, "prefix", "command", {"arg", ""}));
}

TEST(Irc, SimpleTag) {
  char input[] = "@key=val :prefix command arg :";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({{"key", "val"}}, "prefix", "command", {"arg", ""}));
}

TEST(Irc, TwoTags) {
  char input[] = "@key=val;yek=eulav :prefix command";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({{"key","val"}, {"yek","eulav"}}, "prefix", "command", {}));
}

TEST(Irc, FirstTagNoValue) {
  char input[] = "@key;yek=eulav :prefix command";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({{"key", {}}, {"yek", "eulav"}}, "prefix", "command", {}));
}

TEST(Irc, TagEscapes) {
  ircmsg expect {
    {{"key", {}}, {"yek", "; \\\r\n"}},
    "prefix", "command", {}};
  char input[] = "@key;yek=\\:\\s\\\\\\r\\n :prefix command";
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, LoneTagNoValue) {
  ircmsg expect {{{"key",""}}, "pfx", "command", {}};
  char input[] = "@key= :pfx command";
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagTrailingBackslash) {
  struct ircmsg expect = {{{"key","x"}}, {}, "command", {}};
  char input[] = "@key=x\\ command";
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagBadEscape) {
  ircmsg expect {{{"key","x"},{"yek", {}}}, {}, "command", {}};
  char input[] = "@key=\\x\\;yek command";
  EXPECT_EQ(parse_irc_message(input), expect);
}

TEST(Irc, TagKeyUnescaped) {
  char input[] = "@k\\s=x command";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({{"k\\s", "x"}}, {}, "command", {}));
}

TEST(Irc, TwoEmptyTagValues) {
  char input[] = "@key=;yek= command";
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({{"key", ""}, {"yek", ""}}, {}, "command", {}));
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
  EXPECT_EQ(
    parse_irc_message(input),
    ircmsg({}, "", "command", {}));
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
