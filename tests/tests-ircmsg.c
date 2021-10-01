#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <check.h>

#include "ircmsg.h"

static void
testcase(char *input, struct ircmsg const* expected) {
  struct ircmsg got;
  int result = parse_irc_message(input, &got);

  if (NULL == expected) {
    ck_assert_int_ne(result, 0);
    return;
  }

  ck_assert_int_eq(result, 0);
  ck_assert_int_eq(expected->tags_n, got.tags_n);
  ck_assert_int_eq(expected->args_n, got.args_n);

  ck_assert_pstr_eq(expected->source, got.source);
  ck_assert_str_eq(expected->command, got.command);

  for (int i = 0; i < got.tags_n; i++) {
    ck_assert_str_eq(expected->tags[i].key, got.tags[i].key);
    ck_assert_pstr_eq(expected->tags[i].val, got.tags[i].val);
  }

  for (int i = 0; i < got.args_n; i++) {
    ck_assert_str_eq(expected->args[i], got.args[i]);
  }
}

START_TEST(test_no_args) {
  struct ircmsg expect = {
      .command = "cmd",
      .args_n = 0,
  };
  char input[] = "cmd";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_no_args_trailing) {
  struct ircmsg expect = {
      .command = "cmd",
      .args_n = 0,
  };
  char input[] = "cmd ";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_one_arg) {
  struct ircmsg expect = {
      .command = "cmd",
      .args_n = 1,
      .args = {"arg"},
  };
  char input[] = "cmd arg";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_command_arg_spaced) {
  struct ircmsg expect = {
      .command = "cmd",
      .args_n = 1,
      .args = {"arg"},
  };
  char input[] = "  cmd  arg  ";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_command_arg_colon) {
  struct ircmsg expect = {
      .command = "command",
      .args_n = 2,
      .args = {"arg", "arg2"},
  };
  char input[] = "command arg :arg2";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_colon_arg) {
  struct ircmsg expect = {
      .command = "command",
      .args_n = 2,
      .args = {"arg", "arg2  more"},
  };
  char input[] = "command arg :arg2  more";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_internal_colon) {
  struct ircmsg expect = {
      .command = "command",
      .args_n = 1,
      .args = {"arg:arg2"},
  };
  char input[] = "command arg:arg2";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_max_args) {
  struct ircmsg expect = {
      .command = "command",
      .args_n = 15,
      .args = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12",
               "13", "14", "15 16"},
  };
  char input[] = "command 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_max_args_colon)
{
  struct ircmsg expect = {
      .command = "command",
      .args_n = 15,
      .args = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12",
               "13", "14", "15 16"},
  };
  char input[] = "command 1 2 3 4 5 6 7 8 9 10 11 12 13 14 :15 16";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_bare_prefix)
{
  char input[] = ":prefix";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_bare_prefix_space)
{
  char input[] = ":prefix ";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_prefix)
{
  struct ircmsg expect = {
      .source = "prefix",
      .command = "command",
      .args_n = 2,
      .args = {"arg", "arg2 "},
  };
  char input[] = ":prefix command arg :arg2 ";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_prefix_and_colon) {
  struct ircmsg expect = {
      .source = "prefix",
      .command = "command",
      .args_n = 2,
      .args = {"arg", ""},
  };
  char input[] = ":prefix command arg :";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_simple_tag) {
  struct ircmsg expect = {
      .tags_n = 1,
      .tags[0].key = "key",
      .tags[0].val = "val",
      .source = "prefix",
      .command = "command",
      .args_n = 2,
      .args = {"arg", ""},
  };
  char input[] = "@key=val :prefix command arg :";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_two_tags) {
  struct ircmsg expect = {
      .tags_n = 2,
      .tags[0].key = "key",
      .tags[0].val = "val",
      .tags[1].key = "yek",
      .tags[1].val = "eulav",
      .source = "prefix",
      .command = "command",
  };
  char input[] = "@key=val;yek=eulav :prefix command";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_first_tag_no_value) {
  struct ircmsg expect = {
      .tags_n = 2,
      .tags[0].key = "key",
      .tags[1].key = "yek",
      .tags[1].val = "eulav",
      .source = "prefix",
      .command = "command",
  };
  char input[] = "@key;yek=eulav :prefix command";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_tag_escapes) {
  struct ircmsg expect = {
      .tags_n = 2,
      .tags[0].key = "key",
      .tags[1].key = "yek",
      .tags[1].val = "; \\\r\n",
      .source = "prefix",
      .command = "command",
  };
  char input[] = "@key;yek=\\:\\s\\\\\\r\\n :prefix command";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_lone_tag_no_value) {
  struct ircmsg expect = {
      .tags_n = 1,
      .tags[0].key = "key",
      .tags[0].val = "",
      .source = "pfx",
      .command = "command",
  };
  char input[] = "@key= :pfx command";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_tag_trailing_escape) {
  struct ircmsg expect = {
      .tags_n = 1,
      .tags[0].key = "key",
      .tags[0].val = "x",
      .command = "command",
  };
  char input[] = "@key=x\\ command";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_tag_bad_escape) {
  struct ircmsg expect = {
      .tags_n = 2,
      .tags[0].key = "key",
      .tags[0].val = "x",
      .tags[1].key = "yek",
      .command = "command",
  };
  char input[] = "@key=\\x\\;yek command";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_tag_key_unescaped) {
  struct ircmsg expect = {
      .tags_n = 1,
      .tags[0].key = "k\\s",
      .tags[0].val = "x",
      .command = "command",
  };
  char input[] = "@k\\s=x command";
  testcase(input, &expect);
}
END_TEST

START_TEST(test_two_empty_tag_values) {
  struct ircmsg expect = {
      .tags_n = 2,
      .tags[0].key = "key",
      .tags[0].val = "",
      .tags[1].key = "yek",
      .tags[1].val = "",
      .command = "command",
  };
  char input[] = "@key=;yek= command";
  testcase(input, &expect);
}

START_TEST(test_tag_no_body) {
  char input[] = "@ :pfx command";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_tag_lone_semi) {
  char input[] = "@; command";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_empty_prefix) {
  char input[] = ": command";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_tag_no_key) {
  char input[] = "@=value command";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_tag_trail_semi) {
  char input[] = "@key=value; command";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_tag_no_command) {
  char input[] = "@key=value";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_tag_lone_semi_no_command) {
  char input[] = "@key=value;";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_colon) {
  char input[] = ":";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_empty) {
  char input[] = "";
  testcase(input, NULL);
}
END_TEST

START_TEST(test_spaces) {
  char input[] = "   ";
  testcase(input, NULL);
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
  tcase_add_test(tc_parsing, test_max_args);
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
