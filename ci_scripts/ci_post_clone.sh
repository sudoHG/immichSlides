#!/bin/sh
# Xcode Cloud runs this separately for each archive action, with sources available.
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must provide the repository path}"
exec /usr/bin/python3 -I -B scripts/check_xcode_cloud_archive.py
