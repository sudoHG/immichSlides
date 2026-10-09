#!/bin/sh
# Xcode Cloud runs this once per action, with sources available.
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must provide the repository path}"
if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo "Xcode Cloud post-clone: ${CI_XCODEBUILD_ACTION:-unknown} action; archive preflight not applicable"
  exit 0
fi
exec /usr/bin/python3 -I -B scripts/check_xcode_cloud_archive.py
