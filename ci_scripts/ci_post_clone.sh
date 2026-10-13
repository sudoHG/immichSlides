#!/bin/sh
# Xcode Cloud runs this separately for each action, with sources available.
set -eu

if ( : "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must provide the repository path}" ) 2>/dev/null; then
  :
else
  status=$?
  echo "Cloud post-clone failure: stage=repository-path" >&2
  exit "$status"
fi
if cd "$CI_PRIMARY_REPOSITORY_PATH" 2>/dev/null; then
  :
else
  status=$?
  echo "Cloud post-clone failure: stage=repository-path" >&2
  exit "$status"
fi
case "${CI_XCODEBUILD_ACTION:-}" in
  archive)
    echo "Cloud post-clone stage=archive-preflight"
    exec /usr/bin/python3 -I -B scripts/check_xcode_cloud_archive.py ;;
  build-for-testing)
    echo "Cloud post-clone stage=selection-bootstrap"
    exec /usr/bin/python3 -I -B ci_scripts/cloud_selection.py ;;
  *) echo "Xcode Cloud post-clone: no source preparation for this action" ;;
esac
