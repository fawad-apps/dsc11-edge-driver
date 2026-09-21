#!/usr/bin/env sh
# Run the DSC11 driver test suite. Needs any Lua 5.3+ interpreter.
#   ./test/run.sh          or       lua test/test_endpoints.lua
set -e
cd "$(dirname "$0")/.."
LUA="${LUA:-lua}"
status=0
for t in test/test_endpoints.lua test/test_preferences.lua test/test_template.lua test/test_handlers.lua; do
  echo "=== $t"
  "$LUA" "$t" || status=1
done
exit $status
