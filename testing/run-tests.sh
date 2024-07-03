#!/bin/sh
cd "`dirname "$0"`" || exit 1
if [ ! -n "$LUA_CMD" ]; then
  export LUA_CMD=lua
fi
FAILED=0
for test in tests/*.lua
do
  echo "Running $test"
  $LUA_CMD $test || FAILED=1
done
if [ $FAILED -eq 0 ]; then
  echo "All tests succeeded."
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
