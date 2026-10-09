#!/bin/sh
# The test action has no source checkout; Xcode Cloud makes ci_scripts available.
set -eu

case "${CI_XCODEBUILD_ACTION:-}" in
  test-without-building|test) ;;
  *) exit 0 ;;
esac
[ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || exit 1
[ "${CI_PRODUCT_PLATFORM:-}" = "tvOS" ] || exit 1
[ "${CI_XCODE_SCHEME:-}" = "immichSlides-tvOS" ] || exit 1
umask 077
here=$(cd "$(dirname "$0")" && pwd)
state=/tmp/immichslides-xcc-fixture
mkdir "$state"
fixture_pid=
cleanup() {
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$state"
}
trap cleanup EXIT HUP INT TERM
nohup /usr/bin/python3 -I -B "$here/fixture_server.py" --fixture-set c --host 127.0.0.1 --port 8765 \
  --ready-file "$state/ready.json" > "$state/server.log" 2>&1 &
fixture_pid=$!
echo "$fixture_pid" > "$state/pid"
i=0
while [ "$i" -lt 60 ]; do
  kill -0 "$fixture_pid" 2>/dev/null || break
  if [ -s "$state/ready.json" ]; then
    echo "Xcode Cloud Apple TV fixture set C ready on loopback port 8765"
    trap - EXIT HUP INT TERM
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done
echo "Xcode Cloud fixture server did not become ready within 60 seconds" >&2
exit 1
