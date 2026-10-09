#!/bin/sh
# Xcode Cloud runs this separately for each action, with sources available.
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must provide the repository path}"
if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo "Xcode Cloud post-clone: archive preflight not applicable to this action"
  exit 0
fi
exec /usr/bin/python3 -I -B scripts/check_xcode_cloud_archive.py
