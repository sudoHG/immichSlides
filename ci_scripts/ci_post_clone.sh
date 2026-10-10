#!/bin/sh
# Xcode Cloud runs this separately for each action, with sources available.
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must provide the repository path}"
case "${CI_XCODEBUILD_ACTION:-}" in
  archive) exec /usr/bin/python3 -I -B scripts/check_xcode_cloud_archive.py ;;
  build-for-testing) exec /usr/bin/python3 -I -B ci_scripts/cloud_selection.py ;;
  *) echo "Xcode Cloud post-clone: no source preparation for this action" ;;
esac
