#!/bin/sh
# Probe: report and stop the fixture server after UI tests.
set -u

case "${CI_XCODEBUILD_ACTION:-}" in
  test-without-building|test) ;;
  *) exit 0 ;;
esac
echo "fixture server log tail:"
tail -40 /tmp/immichslides-fixture.log 2>/dev/null || echo "(no log)"
if [ -s /tmp/immichslides-fixture.pid ]; then kill "$(cat /tmp/immichslides-fixture.pid)" 2>/dev/null || true; fi
exit 0
