# Read by cpack when it packages, so the version is that of the checkout at
# that moment, with no reconfigure: <major>.0.<commits on HEAD>. A later
# commit always packages as a later version. Outside a git checkout the
# version is the project's.

if(CPACK_SNOWCONE_GIT AND EXISTS "${CPACK_SNOWCONE_SOURCE_DIR}/.git")
    execute_process(
        COMMAND "${CPACK_SNOWCONE_GIT}" rev-parse --is-shallow-repository
        WORKING_DIRECTORY "${CPACK_SNOWCONE_SOURCE_DIR}"
        OUTPUT_VARIABLE shallow
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    # a shallow clone counts only the commits it fetched
    if(shallow STREQUAL "true")
        message(FATAL_ERROR "Packaging needs the full history to number the version; run git fetch --unshallow")
    endif()

    execute_process(
        COMMAND "${CPACK_SNOWCONE_GIT}" rev-list --count HEAD
        WORKING_DIRECTORY "${CPACK_SNOWCONE_SOURCE_DIR}"
        OUTPUT_VARIABLE commits
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
    set(CPACK_PACKAGE_VERSION_MINOR 0)
    set(CPACK_PACKAGE_VERSION_PATCH "${commits}")
    set(CPACK_PACKAGE_VERSION "${CPACK_PACKAGE_VERSION_MAJOR}.0.${commits}")
    # named at configure time with the old version; the .deb is named by
    # CPACK_DEBIAN_FILE_NAME instead
    set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${CPACK_PACKAGE_VERSION}-${CPACK_SYSTEM_NAME}")
endif()
