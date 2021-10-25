#ifndef MY_BASE64_H
#define MY_BASE64_H

#include <stddef.h>
#include <sys/types.h>

void mybase64_encode(char const* input, size_t len, char *output);
ssize_t mybase64_decode(char const* input, size_t len, char *output);

#endif
