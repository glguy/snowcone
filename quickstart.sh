#!/bin/sh
set -e
BUILD_DIR=build
cmake -DBUILD_TESTING=OFF -B "${BUILD_DIR}"
cmake --build "${BUILD_DIR}"
