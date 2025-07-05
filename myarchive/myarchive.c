#include "myarchive.h"

#include <archive.h>
#include <archive_entry.h>
#include <lua.h>
#include <lauxlib.h>

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static int l_get_archive_file(lua_State* const L)
{
    char const* const archive = luaL_checkstring(L, 1);
    char const* const target = luaL_checkstring(L, 2);

    struct archive * const a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    if (ARCHIVE_OK != archive_read_open_filename(a, archive, 10240))
    {
        luaL_pushfail(L);
        lua_pushstring(L, archive_error_string(a));
        archive_read_free(a);
        return 2;
    }

    struct archive_entry *entry = NULL;
    for(;;) {
        switch (archive_read_next_header(a, &entry)) {
            case ARCHIVE_OK:
            case ARCHIVE_WARN:
                if (0 == strcmp(target, archive_entry_pathname_utf8(entry)))
                {
                    luaL_Buffer B;
                    la_int64_t const size = archive_entry_size(entry);
                    char* const buff = luaL_buffinitsize(L, &B, size);
                    archive_read_data(a, buff, size);
                    archive_read_free(a);
                    luaL_pushresultsize(&B, size);
                    return 1;
                }
                break;

            case ARCHIVE_EOF:
                archive_read_free(a);
                luaL_pushfail(L);
                lua_pushstring(L, "entry not found");
                return 2;

            case ARCHIVE_RETRY:
                break;

            case ARCHIVE_FATAL:
                luaL_pushfail(L);
                lua_pushstring(L, archive_error_string(a));
                archive_read_free(a);
                return 2;

            default:
                abort();
        }
    }
}

static int l_get_archive(lua_State* const L)
{
    char const* const archive = luaL_checkstring(L, 1);

    struct archive * const a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    if (ARCHIVE_FAILED == archive_read_open_filename(a, archive, 10240))
    {
        luaL_pushfail(L);
        lua_pushstring(L, archive_error_string(a));
        archive_read_free(a);
        return 2;
    }

    lua_newtable(L);

    for (struct archive_entry *entry = NULL;;) {
        int const result = archive_read_next_header(a, &entry);
        switch (result) {
            case ARCHIVE_OK:
            case ARCHIVE_WARN:

                lua_pushstring(L, archive_entry_pathname_utf8(entry));

                luaL_Buffer B;
                la_int64_t const size = archive_entry_size(entry);
                char* const buff = luaL_buffinitsize(L, &B, size);
                archive_read_data(a, buff, size);
                luaL_pushresultsize(&B, size);
                lua_rawset(L, -3);
                break;

            case ARCHIVE_EOF:
                archive_read_free(a);
                return 1;

            case ARCHIVE_RETRY:
                break;

            case ARCHIVE_FATAL:
            case ARCHIVE_FAILED:
                luaL_pushfail(L);
                lua_pushstring(L, archive_error_string(a));
                archive_read_free(a);
                return 2;

            default:
                abort();
        }
    }
}

static int l_save_archive(lua_State * const L)
{
    const char * const filename = luaL_checkstring(L, 1);
    luaL_checkany(L, 2);
    lua_settop(L, 2);

    int const fd = open(filename, O_WRONLY | O_CREAT, 0666);
    if (-1 == fd)
    {
        luaL_pushfail(L);
        lua_pushstring(L, strerror(errno));
        return 2;
    }

    struct archive *a = archive_write_new();
    struct archive_entry * entry = archive_entry_new();

    if (ARCHIVE_OK != archive_write_set_format_filter_by_ext(a, filename))
    {
        archive_write_add_filter_gzip(a);
        archive_write_set_format_ustar(a);
    }

    if (ARCHIVE_OK != archive_write_open_fd(a, fd))
    {
        close(fd);
        luaL_pushfail(L);
        lua_pushstring(L, archive_error_string(a));
        archive_write_free(a);
        return 2;
    }

    lua_pushnil(L);
    while (0 != lua_next(L, 2))
    {
        const char * const entry_name = luaL_tolstring(L, -2, NULL);
        size_t data_len;
        const char * const data = luaL_tolstring(L, -2, &data_len);

        archive_entry_clear(entry);
        archive_entry_set_pathname_utf8(entry, entry_name);
        archive_entry_set_size(entry, data_len);
        archive_entry_set_mode(entry, AE_IFREG | 0666);

        if (ARCHIVE_OK != archive_write_header(a, entry))
        {
            luaL_pushfail(L);
            lua_pushstring(L, archive_error_string(a));
            archive_entry_free(entry);
            archive_write_free(a);
            return 2;
        }

        if (0 > archive_write_data(a, data, data_len))
        {
            luaL_pushfail(L);
            lua_pushstring(L, archive_error_string(a));
            archive_entry_free(entry);
            archive_write_free(a);
            return 2;
        }

        lua_pop(L, 3);
    }

    archive_entry_free(entry);
    archive_write_free(a);

    lua_pushboolean(L, 1);
    return 1;
}

static luaL_Reg const M[] = {
    {"get_archive_file", l_get_archive_file},
    {"get_archive", l_get_archive},
    {"save_archive", l_save_archive},
    {0}
};

int luaopen_myarchive(lua_State* const L)
{
    luaL_newlib(L, M);
    return 1;
}
