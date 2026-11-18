"""Git-object input and an isolated base-revision verdict reader.

Candidate trees are text only. Only the admitted first parent's allowlisted
reader modules are ever materialized as executable Python.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from ci_summary import require, sha

BASE_MODULES = ("ci_summary.py", "ci_population.py", "ci_verdict.py", "ui_test_inventory.py",
                "run_host_checks.py")
OPTIONAL_BASE_MODULES = ("ci_failure_diagnostics.py", "ci_bounded_diagnostics.py")
BRIDGE = """import json,sys
sys.path.insert(0, sys.argv[1])
from ci_verdict import classify_changes
p=json.load(sys.stdin)
if p['operation']=='classify':
    result=classify_changes(p['paths'],p['classification_policy'],build_target_paths=p['build_target_paths'])
elif p['operation']=='host':
    from run_host_checks import host_partition
    result={'host-'+scope:host_partition(p['population'],scope) for scope in ('linux','macos')}
else:
    raise ValueError('unsupported base reader operation')
print(json.dumps(result))
"""


def git(*arguments, binary=False):
    result = subprocess.run(["git", *arguments], check=True, capture_output=True, timeout=90)
    return result.stdout if binary else result.stdout.decode("utf-8").strip()


def read_blob(commit, path):
    sha(commit)
    return git("show", commit + ":" + path, binary=True).decode("utf-8")


def tree_inputs(commit):
    sha(commit)
    entries = git("ls-tree", "-rz", "--full-tree", commit, binary=True).split(b"\0")
    listing, sources = [], {}
    for entry in filter(None, entries):
        metadata, raw_path = entry.split(b"\t", 1)
        mode, kind, object_sha = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        listing.append({"path": path, "mode": mode, "type": kind, "sha": object_sha})
        if ((path.startswith("scripts/") and path.endswith(".py")) or
                (path.startswith(("immichSlidesTests/", "immichSlidesUITests/")) and path.endswith(".swift"))):
            require(mode == "100644" or mode == "100755", "test source is not a regular blob")
            sources[path] = read_blob(commit, path)
    return listing, sources


def base_reader(modules, payload):
    require(set(BASE_MODULES) <= set(modules) <= set(BASE_MODULES + OPTIONAL_BASE_MODULES),
            "incomplete or unreviewed trusted base reader")
    with tempfile.TemporaryDirectory(prefix="ci-base-reader-") as directory:
        for name, source in modules.items():
            Path(directory, name).write_text(source, encoding="utf-8")
        # No credentials or candidate-controlled Python startup variables cross
        # into the historical reader. Candidate bodies are only JSON input.
        environment = {key: value for key, value in os.environ.items()
                       if key in {"PATH", "SYSTEMROOT", "LANG", "TMPDIR"}}
        result = subprocess.run([sys.executable, "-I", "-B", "-c", BRIDGE, directory],
                                input=json.dumps(payload), capture_output=True, text=True,
                                env=environment, timeout=120)
        require(result.returncode == 0, "base reader refused static inputs")
        return json.loads(result.stdout)


def revision_modules(revision):
    modules = {name: read_blob(revision, "scripts/" + name) for name in BASE_MODULES}
    # These dependencies were introduced after the original verdict library.
    # Missing historical files are allowed; present files come from that base.
    for name in OPTIONAL_BASE_MODULES:
        if git("ls-tree", "--name-only", revision, "--", "scripts/" + name):
            modules[name] = read_blob(revision, "scripts/" + name)
    return modules
