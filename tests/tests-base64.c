#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <check.h>

#include "mybase64.h"

START_TEST(test_encode_foobar)
{
    char buffer[9];

    mybase64_encode("", 0, buffer);
    ck_assert_str_eq("", buffer);

    mybase64_encode("f", 1, buffer);
    ck_assert_str_eq("Zg==", buffer);

    mybase64_encode("fo", 2, buffer);
    ck_assert_str_eq("Zm8=", buffer);

    mybase64_encode("foo", 3, buffer);
    ck_assert_str_eq("Zm9v", buffer);

    mybase64_encode("foob", 4, buffer);
    ck_assert_str_eq("Zm9vYg==", buffer);

    mybase64_encode("fooba", 5, buffer);
    ck_assert_str_eq("Zm9vYmE=", buffer);

    mybase64_encode("foobar", 6, buffer);
    ck_assert_str_eq("Zm9vYmFy", buffer);
}


START_TEST(test_decode_foobar)
{
    ssize_t len;
    char buffer[6];

    len = mybase64_decode("", 0, buffer);
    ck_assert_int_eq(len, 0);

    len = mybase64_decode("Zg==", 4, buffer);
    ck_assert_int_eq(len, 1);
    ck_assert_mem_eq(buffer, "f", 1);

    len = mybase64_decode("Zm8=", 4, buffer);
    ck_assert_int_eq(len, 2);
    ck_assert_mem_eq(buffer, "fo", 2);

    len = mybase64_decode("Zm9v", 4, buffer);
    ck_assert_int_eq(len, 3);
    ck_assert_mem_eq(buffer, "foo", 3);

    len = mybase64_decode("Zm9vYg==", 8, buffer);
    ck_assert_int_eq(len, 4);
    ck_assert_mem_eq(buffer, "foob", 4);

    len = mybase64_decode("Zm9vYmE=", 8, buffer);
    ck_assert_int_eq(len, 5);
    ck_assert_mem_eq(buffer, "fooba", 5);

    len = mybase64_decode("Zm9vYmFy", 8, buffer);
    ck_assert_int_eq(len, 6);
    ck_assert_mem_eq(buffer, "foobar", 6);
}

START_TEST(test_exhaust1)
{
    for (int i = 0; i < 256; i++)
    {
        uint8_t input = i;
        char output64[5];
        uint8_t recovered;

        mybase64_encode((char*)&input, 1, output64);
        ssize_t len = mybase64_decode(output64, strlen(output64), (char*)&recovered);

        ck_assert_int_eq(len, 1);
        ck_assert_int_eq(recovered, input);
    }
}
END_TEST

int main(void)
{
    Suite *s = suite_create("mybase64");
    TCase *tc = tcase_create("Tests");

    suite_add_tcase(s, tc);

    tcase_add_test(tc, test_encode_foobar);
    tcase_add_test(tc, test_decode_foobar);
    tcase_add_test(tc, test_exhaust1);

    SRunner *sr = srunner_create(s);
    srunner_run_all(sr, CK_ENV);

    int number_failed = srunner_ntests_failed(sr);
    return (number_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
