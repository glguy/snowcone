#!/bin/sh

# Line coverage of hub by its tests.
#
# Usage: tests/hub/tools/coverage.sh [OUTDIR]
#
# Runs every hub test, and the SASL tests, under luacov (luarocks install
# luacov luafilesystem), then writes OUTDIR/luacov.report.out, hub's
# source with each line's hit count, and prints each file's coverage,
# worst first. Files no test loads are listed at 0%. OUTDIR defaults to
# out/coverage. SNOWCONE names the client to run the tests with
# (default: snowcone on the PATH).
#
# The count is of lines run, not of behavior checked: a line can run
# under a test that would pass without it. tests/hub/tools/mutate.lua
# measures that.

set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=${1:-"$root/out/coverage"}
snowcone=${SNOWCONE:-snowcone}

mkdir -p "$out"
rm -f "$out"/*.stats "$out"/*.log
cd "$root"

failed=
for test in tests/hub/test-*.lua tests/test-sasl.lua tests/test-scram.lua; do
    name=$(basename "$test" .lua)
    status=0
    "$snowcone" "$here/coverage.lua" run "$out/$name.stats" "$test" >"$out/$name.log" 2>&1 || status=$?
    # 77 is a test skipping for a library it lacks
    if [ "$status" -ne 0 ] && [ "$status" -ne 77 ]; then
        failed="$failed $name"
    fi
done

lua "$here/coverage.lua" merge "$out/hub.stats" "$out"/test-*.stats

cat >"$out/luacov.config" <<EOF
return {
    statsfile = '$out/hub.stats',
    reportfile = '$out/luacov.report.out',
    include = {'^hub/'},
    exclude = {'^hub/types\$'},
    includeuntestedfiles = {'hub'},
}
EOF
luacov -c "$out/luacov.config"

# Each file's coverage, worst first, then the total
sed -n '/^Summary/,$p' "$out/luacov.report.out" | grep '^File'
sed -n '/^Summary/,$p' "$out/luacov.report.out" | grep '^hub/' | sort -n -k4
grep '^Total' "$out/luacov.report.out"
echo "report: $out/luacov.report.out"

if [ -n "$failed" ]; then
    echo "tests that failed (their logs are in $out):$failed" >&2
    exit 1
fi
