#!/bin/sh
set -e
BUILD_DIR=build
cmake -DBUILD_TESTING=OFF -B "${BUILD_DIR}"
make -C "${BUILD_DIR}"
