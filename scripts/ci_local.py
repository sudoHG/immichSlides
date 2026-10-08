"""CI-equivalent local execution from an isolated snapshot, without changing refs."""

from contextlib import contextmanager
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

PRIVATE_PATHS = ("Config/env.xcconfig", "immichSlides/Config/env.xcconfig")
CONTEXT = "_IMMICHSLIDES_CI_LOCAL_ROOT"
MODE_CONTEXT = "_IMMICHSLIDES_CI_LOCAL_MODE"
PATH_OPTIONS = {"--output-dir", "--evidence-dir", "--derived-data-path", "--result-bundle-path",
                "--cloned-source-packages-path", "--cloned-source-packages", "--xctestrun",
                "--archive-dir", "--selection-path", "--relocated-path", "--shard-manifest"}


def forbidden_input(key):
    for prefix in ("TEST_RUNNER_", "SIMCTL_CHILD_"):
        if key.startswith(prefix):
            return forbidden_input(key[len(prefix):])
    return key.startswith(("IMMICH", "UI_TEST_", "STRICT_E2E_", "ENABLE_DEBUG_", "SMARTFILL_",
                           "SCENE_PRESENTATION_")) or key == "XCODE_XCCONFIG_FILE"


def clean_environment(source, explicit=()):
    environment = {key: value for key, value in source.items()
                   if not forbidden_input(key) and not key.startswith("GITHUB_")}
    for entry in explicit:
        key, separator, value = entry.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or not forbidden_input(key) or key == "XCODE_XCCONFIG_FILE" or "\n" in value or "\0" in value:
            raise ValueError("--config requires a test configuration NAME=VALUE; process/toolchain overrides are refused")
        environment[key] = value
    return environment


def select_mode(arguments):
    private, strict = "--allow-private-config" in arguments, "--strict-ci" in arguments
    if private and strict:
        raise ValueError("--strict-ci and --allow-private-config cannot be combined")
    return "private" if private else "strict" if strict else "snapshot"


def git(root, *args, environment=None, input=None):
    return subprocess.check_output(["git", "--no-optional-locks", "-c", "core.fsmonitor=false", *args], cwd=root,
                                   env=environment, input=input, stderr=subprocess.PIPE, timeout=120).decode().strip()


@contextmanager
def snapshot(root, *, strict=False):
    root = root.resolve()
    environment = dict(os.environ)
    for key in ("GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_DIR", "GIT_COMMON_DIR"):
        environment.pop(key, None)
    head = git(root, "rev-parse", "HEAD", environment=environment)
    dirty = bool(git(root, "status", "--porcelain", "--untracked-files=all", environment=environment))
    if strict and dirty:
        raise ValueError("strict CI-equivalent mode refuses tracked changes and untracked, non-ignored files")
    with tempfile.TemporaryDirectory(prefix="immichslides-local-") as directory:
        directory = Path(directory)
        index_environment = {**environment, "GIT_INDEX_FILE": str(directory / "index")}
        git(root, "read-tree", head, environment=index_environment)
        names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                        cwd=root, env=environment, timeout=120).split(b"\0")
        committed = subprocess.check_output(["git", "ls-tree", "-rz", "--name-only", head],
                                            cwd=root, env=environment, timeout=120).split(b"\0")
        paths = sorted((set(names) | set(committed)) - {b"", *(path.encode() for path in PRIVATE_PATHS)})
        paths = [path for path in paths if path in committed or os.path.lexists(root / os.fsdecode(path))]
        if paths:
            git(root, "add", "--all", "--pathspec-from-file=-", "--pathspec-file-nul",
                environment=index_environment, input=b"\0".join(b":(literal)" + path for path in paths) + b"\0")
        # Exclusion also applies if a malformed tree tracked private configuration.
        git(root, "update-index", "--force-remove", "--", *PRIVATE_PATHS, environment=index_environment)
        tree = git(root, "write-tree", environment=index_environment)
        commit_environment = {**environment, "GIT_AUTHOR_NAME": "sudoHG", "GIT_AUTHOR_EMAIL": "by331works@gmail.com",
                              "GIT_COMMITTER_NAME": "sudoHG", "GIT_COMMITTER_EMAIL": "by331works@gmail.com"}
        # Equal source/tree inputs need equal identities across separate build/consumer calls.
        timestamp = git(root, "show", "-s", "--format=%ct", head, environment=environment)
        commit_environment.update(GIT_AUTHOR_DATE="@" + timestamp + " +0000",
                                  GIT_COMMITTER_DATE="@" + timestamp + " +0000")
        commit = git(root, "commit-tree", tree, "-p", head, environment=commit_environment,
                     input=b"Temporary local test snapshot\n")
        checkout = (directory / "source").resolve()
        git(root, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet", "--detach", str(checkout), commit,
            environment=environment)
        try:
            if any(os.path.lexists(checkout / path) for path in PRIVATE_PATHS):
                raise ValueError("snapshot contains private configuration")
            yield checkout, {"schema_version": 1, "mode": "strict" if strict else "snapshot",
                             "source_commit_sha": head, "source_dirty": dirty,
                             "commit_sha": commit, "tree_sha": tree, "private_configuration": False}
        finally:
            git(root, "worktree", "remove", "--force", str(checkout), environment=environment)


def absolute_paths(arguments, cwd):
    result = list(arguments)
    for index, argument in enumerate(result[:-1]):
        if argument in PATH_OPTIONS:
            result[index + 1] = str((cwd / result[index + 1]).resolve())
    for index, argument in enumerate(result):
        option, separator, value = argument.partition("=")
        if separator and option in PATH_OPTIONS:
            result[index] = option + "=" + str((cwd / value).resolve())
    return result


def option_value(arguments, names):
    value = None
    for index, argument in enumerate(arguments):
        option, separator, inline = argument.partition("=")
        if option in names:
            if separator:
                value = inline
            elif index + 1 < len(arguments):
                value = arguments[index + 1]
    return value


def run_child(command, root, environment):
    process = subprocess.Popen(command, cwd=root, env=environment, start_new_session=True)
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        return process.wait()
    except KeyboardInterrupt:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 130
    finally:
        signal.signal(signal.SIGTERM, previous)


def launch(script, arguments):
    root = script.resolve().parent.parent
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--strict-ci", action="store_true")
    parser.add_argument("--allow-private-config", action="store_true")
    parser.add_argument("--config", action="append", default=[])
    parser.add_argument("--snapshot-record", type=Path)
    options, remaining = parser.parse_known_args(arguments)
    mode = select_mode(arguments)
    if "--prepare-example-config" in remaining:
        # This explicit setup operation must affect the caller's checkout.
        if any(flag in remaining for flag in ("--platform", "--full-plan")):
            raise ValueError("prepare local configuration separately before a CI-equivalent run")
        mode = "private"
    environment = clean_environment(os.environ, options.config)
    environment.pop(CONTEXT, None)
    environment.pop(MODE_CONTEXT, None)
    remaining = absolute_paths(remaining, Path.cwd())
    for index, argument in enumerate(remaining[:-1]):
        if argument == "--project":
            project = (Path.cwd() / remaining[index + 1]).resolve()
            if root not in project.parents:
                raise ValueError("--project must belong to the source checkout being snapshotted")
            remaining[index + 1] = str(project.relative_to(root))
    record_path = options.snapshot_record.resolve() if options.snapshot_record else None
    output_value = option_value(remaining, {"--output-dir", "--evidence-dir"})
    output = Path(output_value) if output_value else None
    if output and (output == root or root in output.parents):
        raise ValueError("output/evidence directory must be outside the source checkout")
    if record_path is None and output:
        record_path = output / "local-snapshot.json"
    if record_path and (record_path == root or root in record_path.parents):
        raise ValueError("snapshot record must be outside the source checkout")
    if record_path and os.path.lexists(record_path):
        raise ValueError("snapshot record must be fresh; refusing to overwrite an earlier receipt")

    def execute(checkout, receipt):
        environment[CONTEXT] = str(checkout.resolve())
        environment[MODE_CONTEXT] = receipt["mode"]
        target = checkout / script.relative_to(root)
        child_arguments = list(remaining)
        if target.name == "run_offline_unit_tests.py" and "--derived-data-path" not in child_arguments and not any(
                argument.startswith("--derived-data-path=") for argument in child_arguments):
            child_arguments += ["--derived-data-path", str(checkout / ".derivedData/offline-local")]
        command = (["bash", str(target)] if target.suffix == ".sh" else [sys.executable, "-B", str(target)]) + child_arguments
        print("Local mode: " + receipt["mode"] + "; tested tree: " + (receipt["tree_sha"] or "unrecorded (original checkout)"), flush=True)
        code = run_child(command, checkout, environment)
        receipt.update(exit_code=code, explicit_configuration_keys=[entry.partition("=")[0] for entry in options.config])
        if record_path:
            record_path.parent.mkdir(parents=True, exist_ok=True)
            record_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        return code

    if mode == "private":
        receipt = {"schema_version": 1, "mode": "private", "source_commit_sha": git(root, "rev-parse", "HEAD"),
                   "tree_sha": None, "source_dirty": bool(git(root, "status", "--porcelain")),
                   "private_configuration": any(os.path.lexists(root / path) for path in PRIVATE_PATHS)}
        return execute(root, receipt)
    with snapshot(root, strict=mode == "strict") as (checkout, receipt):
        return execute(checkout, receipt)


def local_main(main, filename):
    script = Path(filename).resolve()
    root = script.parent.parent
    # Hosted producers retain their admitted identity and checkout contracts.
    hosted = os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
    nested = os.environ.get(CONTEXT) == str(root)
    if nested and os.environ.get(MODE_CONTEXT) != "private" and any(os.path.lexists(root / path) for path in PRIVATE_PATHS):
        nested = False
    if hosted or nested:
        return main()
    if "--help" in sys.argv or "-h" in sys.argv:
        print("Local defaults: isolated working-tree snapshot; no ambient/private configuration.\n"
              "  --strict-ci              Refuse a dirty working tree.\n"
              "  --allow-private-config   Explicitly use the caller's local configuration.\n"
              "  --config NAME=VALUE      Explicit runtime test configuration (repeatable).\n"
              "  --snapshot-record PATH   Keep the tested tree receipt outside the checkout.\n")
        return main()
    try:
        return launch(script, sys.argv[1:])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Local preflight refused: " + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        return 2


if __name__ == "__main__":
    try:
        raise SystemExit(launch(Path(sys.argv[1]), sys.argv[2:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Local preflight refused: " + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        raise SystemExit(2)
