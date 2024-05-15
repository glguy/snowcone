#include "myarchive.h"

#include <archive.h>
#include <archive_entry.h>
#include <lua.h>
#include <lauxlib.h>

#include <stdlib.h>
#include <string.h>

static int l_get_archive_file(lua_State* const L)
{
    char const* const archive = luaL_checkstring(L, 1);
    char const* const target = luaL_checkstring(L, 2);

    struct archive * const a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    if (ARCHIVE_FAILED == archive_read_open_filename(a, archive, 10240))
    {
        char const* const errmsg = archive_error_string(a);
        archive_read_free(a);
        return luaL_error(L, "Failed to open archive: %s", errmsg);
    }

    for (struct archive_entry *entry = NULL;;) {
        int const result = archive_read_next_header(a, &entry);
        switch (result) {
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
                return luaL_error(L, "Module not found in archive");
                break;

            case ARCHIVE_RETRY:
                break;

            case ARCHIVE_FATAL:
                archive_read_free(a);
                return luaL_error(L, "Fatal error searching archive");

            default:
                abort();
        }
    }

    return 0;
}

static luaL_Reg const M[] = {
    {"get_archive_file", l_get_archive_file},
    {0}
};

int luaopen_myarchive(lua_State* const L)
{
    luaL_newlib(L, M);
    return 1;
}
