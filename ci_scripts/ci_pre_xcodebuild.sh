#!/bin/sh
# Probe: start the public fixture server before Xcode Cloud runs UI tests.
set -eu

echo "Xcode Cloud pre-xcodebuild: action=${CI_XCODEBUILD_ACTION:-unknown} platform=${CI_PRODUCT_PLATFORM:-unknown}"
case "${CI_XCODEBUILD_ACTION:-}" in
  test-without-building|test) ;;
  *) exit 0 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
rm -f /tmp/immichslides-fixture-ready.json
nohup /usr/bin/python3 -I -B "$here/fixture_server.py" --fixture-set c --host 127.0.0.1 --port 8765 \
  --ready-file /tmp/immichslides-fixture-ready.json > /tmp/immichslides-fixture.log 2>&1 &
echo $! > /tmp/immichslides-fixture.pid
i=0
while [ $i -lt 60 ]; do
  if [ -s /tmp/immichslides-fixture-ready.json ]; then
    echo "fixture server ready: $(cat /tmp/immichslides-fixture-ready.json)"
    exit 0
  fi
  i=$((i + 1)); sleep 1
done
echo "fixture server did not become ready" >&2
tail -20 /tmp/immichslides-fixture.log >&2 || true
exit 1
