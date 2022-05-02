#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <check.h>

#include "ircmsg.hpp"

static void
testcase_bad(char *input) {
  try {
    ircmsg got = parse_irc_message(input);
    ck_abort();
  } catch (irc_parse_error const& e) {
  }
}

static void
testcase(char *input, ircmsg const& expected) {

  try {
    ircmsg got = parse_irc_message(input);

    ck_assert_int_eq(expected.tags.size(), got.tags.size());
    ck_assert_int_eq(expected.args.size(), got.args.size());

    ck_assert_pstr_eq(expected.source, got.source);
    ck_assert_str_eq(expected.command, got.command);

    for (int i = 0; i < got.tags.size(); i++) {
      ck_assert_str_eq(expected.tags[i].key, got.tags[i].key);
      ck_assert_pstr_eq(expected.tags[i].val, got.tags[i].val);
    }

    for (int i = 0; i < got.args.size(); i++) {
      ck_assert_str_eq(expected.args[i], got.args[i]);
    }
  } catch (irc_parse_error const& e) {
    ck_abort();
  }
}

START_TEST(test_no_args) {
  ircmsg expect { {}, nullptr, "cmd", {}};
  char input[] = "cmd";
  testcase(input, expect);
}
END_TEST

START_TEST(test_no_args_trailing) {
  struct ircmsg expect {{}, nullptr, "cmd", {}};
  char input[] = "cmd ";
  testcase(input, expect);
}
END_TEST

START_TEST(test_one_arg) {
  ircmsg expect {{}, nullptr, "cmd", {"arg"}};
  char input[] = "cmd arg";
  testcase(input, expect);
}
END_TEST

START_TEST(test_command_arg_spaced) {
  ircmsg expect {{}, nullptr, "cmd", {"arg"}};
  char input[] = "  cmd  arg  ";
  testcase(input, expect);
}
END_TEST

START_TEST(test_command_arg_colon) {
  ircmsg expect {{}, nullptr, "command", {"arg", "arg2"}};
  char input[] = "command arg :arg2";
  testcase(input, expect);
}
END_TEST

START_TEST(test_colon_arg) {
  ircmsg expect {{}, nullptr, "command", {"arg", "arg2  more"}};
  char input[] = "command arg :arg2  more";
  testcase(input, expect);
}
END_TEST

START_TEST(test_internal_colon) {
  ircmsg expect = {{}, nullptr, "command", {"arg:arg2"}};
  char input[] = "command arg:arg2";
  testcase(input, expect);
}
END_TEST

START_TEST(test_max_args_colon)
{
  struct ircmsg expect = {{}, nullptr, "command", {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15 16"}};

  char input[] = "command 1 2 3 4 5 6 7 8 9 10 11 12 13 14 :15 16";
  testcase(input, expect);
}
END_TEST

START_TEST(test_bare_prefix)
{
  char input[] = ":prefix";
  testcase_bad(input);
}
END_TEST

START_TEST(test_bare_prefix_space)
{
  char input[] = ":prefix ";
  testcase_bad(input);
}
END_TEST

START_TEST(test_prefix)
{
  ircmsg expect {{}, "prefix", "command", {"arg", "arg2 "}};
  char input[] = ":prefix command arg :arg2 ";
  testcase(input, expect);
}
END_TEST

START_TEST(test_prefix_and_colon) {
  ircmsg expect {{}, "prefix", "command", {"arg", ""}};
  char input[] = ":prefix command arg :";
  testcase(input, expect);
}
END_TEST

START_TEST(test_simple_tag) {
  ircmsg expect = {{{"key", "val"}}, "prefix", "command", {"arg", ""}};
  char input[] = "@key=val :prefix command arg :";
  testcase(input, expect);
}
END_TEST

START_TEST(test_two_tags) {
  ircmsg expect = {{{"key","val"}, {"yek","eulav"}}, "prefix", "command", {}};
  char input[] = "@key=val;yek=eulav :prefix command";
  testcase(input, expect);
}
END_TEST

START_TEST(test_first_tag_no_value) {
  ircmsg expect {{{"key",nullptr}, {"yek","eulav"}}, "prefix", "command", {}};
  char input[] = "@key;yek=eulav :prefix command";
  testcase(input, expect);
}
END_TEST

START_TEST(test_tag_escapes) {
  ircmsg expect {
    {{"key", nullptr}, {"yek", "; \\\r\n"}},
    "prefix", "command", {}};
  char input[] = "@key;yek=\\:\\s\\\\\\r\\n :prefix command";
  testcase(input, expect);
}
END_TEST

START_TEST(test_lone_tag_no_value) {
  ircmsg expect {{{"key",""}}, "pfx", "command", {}};
  char input[] = "@key= :pfx command";
  testcase(input, expect);
}
END_TEST

START_TEST(test_tag_trailing_escape) {
  struct ircmsg expect = {{{"key","x"}},nullptr, "command", {}};
  char input[] = "@key=x\\ command";
  testcase(input, expect);
}
END_TEST

START_TEST(test_tag_bad_escape) {
  ircmsg expect {{{"key","x"},{"yek",nullptr}}, nullptr, "command", {}};
  char input[] = "@key=\\x\\;yek command";
  testcase(input, expect);
}
END_TEST

START_TEST(test_tag_key_unescaped) {
  ircmsg expect {{}, nullptr, "command", {}};
  expect.tags = {{"k\\s", "x"}};
  char input[] = "@k\\s=x command";
  testcase(input, expect);
}
END_TEST

START_TEST(test_two_empty_tag_values) {
  ircmsg expect = {{}, nullptr, "command", {}};
  expect.tags = {{"key", ""}, {"yek", ""}};
  char input[] = "@key=;yek= command";
  testcase(input, expect);
}

START_TEST(test_tag_no_body) {
  char input[] = "@ :pfx command";
  testcase_bad(input);
}
END_TEST

START_TEST(test_tag_lone_semi) {
  char input[] = "@; command";
  testcase_bad(input);
}
END_TEST

START_TEST(test_empty_prefix) {
  char input[] = ": command";
  testcase_bad(input);
}
END_TEST

START_TEST(test_tag_no_key) {
  char input[] = "@=value command";
  testcase_bad(input);
}
END_TEST

START_TEST(test_tag_trail_semi) {
  char input[] = "@key=value; command";
  testcase_bad(input);
}
END_TEST

START_TEST(test_tag_no_command) {
  char input[] = "@key=value";
  testcase_bad(input);
}
END_TEST

START_TEST(test_tag_lone_semi_no_command) {
  char input[] = "@key=value;";
  testcase_bad(input);
}
END_TEST

START_TEST(test_colon) {
  char input[] = ":";
  testcase_bad(input);
}
END_TEST

START_TEST(test_empty) {
  char input[] = "";
  testcase_bad(input);
}
END_TEST

START_TEST(test_spaces) {
  char input[] = "   ";
  testcase_bad(input);
}
END_TEST

int main(void) {
  Suite *s = suite_create("ircmsg");
  TCase *tc_parsing = tcase_create("Parsing");

  suite_add_tcase(s, tc_parsing);

  tcase_add_test(tc_parsing, test_no_args);
  tcase_add_test(tc_parsing, test_no_args_trailing);
  tcase_add_test(tc_parsing, test_one_arg);
  tcase_add_test(tc_parsing, test_command_arg_spaced);
  tcase_add_test(tc_parsing, test_command_arg_colon);
  tcase_add_test(tc_parsing, test_colon_arg);
  tcase_add_test(tc_parsing, test_internal_colon);
  tcase_add_test(tc_parsing, test_max_args_colon);
  tcase_add_test(tc_parsing, test_bare_prefix);
  tcase_add_test(tc_parsing, test_bare_prefix_space);
  tcase_add_test(tc_parsing, test_prefix);
  tcase_add_test(tc_parsing, test_prefix_and_colon);
  tcase_add_test(tc_parsing, test_simple_tag);
  tcase_add_test(tc_parsing, test_two_tags);
  tcase_add_test(tc_parsing, test_first_tag_no_value);
  tcase_add_test(tc_parsing, test_tag_escapes);
  tcase_add_test(tc_parsing, test_lone_tag_no_value);
  tcase_add_test(tc_parsing, test_tag_trailing_escape);
  tcase_add_test(tc_parsing, test_tag_bad_escape);
  tcase_add_test(tc_parsing, test_tag_key_unescaped);
  tcase_add_test(tc_parsing, test_two_empty_tag_values);
  tcase_add_test(tc_parsing, test_tag_no_body);
  tcase_add_test(tc_parsing, test_tag_lone_semi);
  tcase_add_test(tc_parsing, test_empty_prefix);
  tcase_add_test(tc_parsing, test_tag_no_key);
  tcase_add_test(tc_parsing, test_tag_trail_semi);
  tcase_add_test(tc_parsing, test_tag_no_command);
  tcase_add_test(tc_parsing, test_tag_lone_semi_no_command);
  tcase_add_test(tc_parsing, test_colon);
  tcase_add_test(tc_parsing, test_empty);
  tcase_add_test(tc_parsing, test_spaces);

  SRunner *sr = srunner_create(s);
  srunner_run_all(sr, CK_ENV);

  int number_failed = srunner_ntests_failed(sr);
  return (number_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
