#!/bin/sh
# Stop only the fixture process started by this action's pre-xcodebuild hook.
set -eu

case "${CI_XCODEBUILD_ACTION:-}" in
  test-without-building|test) ;;
  *) exit 0 ;;
esac
[ "${CI_XCODE_CLOUD:-}" = "TRUE" ] || exit 1
case "${CI_PRODUCT_PLATFORM:-}:${CI_XCODE_SCHEME:-}" in
  iOS:immichSlides-iOS|tvOS:immichSlides-tvOS) ;;
  *) exit 1 ;;
esac
state=/tmp/immichslides-xcc-fixture
[ -f "$state/pid" ] || exit 0
fixture_pid=$(cat "$state/pid")
case "$fixture_pid" in
  ''|*[!0-9]*) echo "Invalid fixture process identity" >&2; exit 1 ;;
esac
if kill -0 "$fixture_pid" 2>/dev/null; then
  command=$(ps -p "$fixture_pid" -o command=)
  case "$command" in
    *"/fixture_server.py --fixture-set c --host 127.0.0.1 --port 8765 --ready-file $state/ready.json"*) ;;
    *) echo "Fixture process identity changed; refusing cleanup" >&2; exit 1 ;;
  esac
  kill "$fixture_pid"
  i=0
  while kill -0 "$fixture_pid" 2>/dev/null; do
    [ "$i" -lt 10 ] || { echo "Fixture process did not stop" >&2; exit 1; }
    i=$((i + 1))
    sleep 1
  done
fi
rm -rf "$state"
echo "Xcode Cloud fixture server stopped"
