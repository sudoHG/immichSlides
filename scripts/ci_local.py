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
import shutil
import time

PRIVATE_PATHS = ("Config/env.xcconfig", "immichSlides/Config/env.xcconfig")
CONTEXT = "_IMMICHSLIDES_CI_LOCAL_ROOT"
MODE_CONTEXT = "_IMMICHSLIDES_CI_LOCAL_MODE"
SOURCE_CONTEXT = "_IMMICHSLIDES_CI_LOCAL_SOURCE"
PATH_OPTIONS = {"--output-dir", "--evidence-dir", "--derived-data-path", "--result-bundle-path",
                "--cloned-source-packages-path", "--cloned-source-packages", "--xctestrun",
                "--archive-dir", "--selection-path", "--relocated-path", "--shard-manifest", "--plan", "--records-dir",
                "--manifest"}
# Commands that only check results an earlier run wrote keep that run's receipt.
RESULT_CHECK_COMMANDS = {"check-upload"}
PATH_ALIASES = {"--derived-data": "--derived-data-path", "--result-bundle": "--result-bundle-path"}
INTERRUPT_GRACE_SECONDS = 150


class SnapshotCleanupError(RuntimeError):
    """Live or unverifiable child processes require retaining their source tree."""


class Interrupted(KeyboardInterrupt):
    def __init__(self, signum):
        self.signum = signum


@contextmanager
def cancellation_signals():
    def interrupted(signum, frame):
        raise Interrupted(signum)
    previous = {signum: signal.signal(signum, interrupted) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


@contextmanager
def ignored_cancellation_signals():
    previous = {signum: signal.signal(signum, signal.SIG_IGN) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


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
    try:
        return subprocess.check_output(["git", "--no-optional-locks", "-c", "core.fsmonitor=false", *args], cwd=root,
                                       env=environment, input=input, stderr=subprocess.PIPE, timeout=120).decode().strip()
    except subprocess.CalledProcessError as error:
        print(error.stderr.decode(errors="replace").strip(), file=sys.stderr)
        raise


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
    directory = Path(tempfile.mkdtemp(prefix="immichslides-local-")).resolve()
    retained = False
    checkout = directory / "source"
    try:
        index_environment = {**environment, "GIT_INDEX_FILE": str(directory / "index")}
        git(root, "read-tree", head, environment=index_environment)
        names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                        cwd=root, env=environment, timeout=120).split(b"\0")
        committed = subprocess.check_output(["git", "ls-tree", "-rz", "--name-only", head],
                                            cwd=root, env=environment, timeout=120).split(b"\0")
        paths = sorted((set(names) | set(committed)) - {b"", *(path.encode() for path in PRIVATE_PATHS)})
        paths = [path for path in paths if path in committed or os.path.lexists(root / os.fsdecode(path))]
        if paths:
            git(root, "add", "--force", "--all", "--pathspec-from-file=-", "--pathspec-file-nul",
                environment=index_environment, input=b"\0".join(b":(literal)" + path for path in paths) + b"\0")
        # Exclusion also applies if a malformed tree tracked private configuration.
        git(root, "update-index", "--force-remove", "--", *PRIVATE_PATHS, environment=index_environment)
        tree = git(root, "write-tree", environment=index_environment)
        commit_environment = {**environment, "GIT_AUTHOR_NAME": "immichSlides local snapshot", "GIT_AUTHOR_EMAIL": "local-snapshot@invalid",
                              "GIT_COMMITTER_NAME": "immichSlides local snapshot", "GIT_COMMITTER_EMAIL": "local-snapshot@invalid"}
        # Equal source/tree inputs need equal identities across separate build/consumer calls.
        timestamp = git(root, "show", "-s", "--format=%ct", head, environment=environment)
        commit_environment.update(GIT_AUTHOR_DATE="@" + timestamp + " +0000",
                                  GIT_COMMITTER_DATE="@" + timestamp + " +0000")
        commit = git(root, "commit-tree", tree, "-p", head, environment=commit_environment,
                     input=b"Temporary local test snapshot\n")
        git(root, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet", "--detach", str(checkout), commit,
            environment=environment)
        try:
            if any(os.path.lexists(checkout / path) for path in PRIVATE_PATHS):
                raise ValueError("snapshot contains private configuration")
            yield checkout, {"schema_version": 1, "mode": "strict" if strict else "snapshot",
                             "source_commit_sha": head, "source_dirty": dirty,
                             "commit_sha": commit, "tree_sha": tree, "private_configuration": False}
        except SnapshotCleanupError:
            retained = True
            raise
        finally:
            if not retained:
                try:
                    # A crashing launcher can orphan a new session between process probes.
                    usage = subprocess.run(["lsof", "-t", "+D", str(checkout)], capture_output=True,
                                           text=True, timeout=30)
                    if usage.returncode != 1 or usage.stdout or usage.stderr:
                        raise SnapshotCleanupError("snapshot process/file occupancy could not be cleared")
                    git(root, "worktree", "remove", "--force", str(checkout), environment=environment)
                except BaseException:
                    retained = True
                    raise
    finally:
        if retained:
            print("Cleanup unverified; snapshot retained: " + str(checkout), file=sys.stderr, flush=True)
        else:
            shutil.rmtree(directory)


def absolute_paths(arguments, cwd):
    result = []
    for argument in arguments:
        option, separator, value = argument.partition("=")
        result.append(PATH_ALIASES.get(option, option) + (separator + value if separator else ""))
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


def process_states():
    raw = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid=,stat="], text=True, timeout=5)
    return [(int(pid), int(parent), int(group), state) for line in raw.splitlines()
            for pid, parent, group, state in [line.split()]]


def remember_groups(process, groups):
    states = process_states()
    groups.intersection_update(group for _, _, group, state in states if not state.startswith("Z"))
    descendants = {process.pid}
    while True:
        found = {pid for pid, parent, _, _ in states if parent in descendants}
        if found <= descendants:
            break
        descendants.update(found)
    groups.update(group for pid, _, group, _ in states if pid in descendants)
    return {group for _, _, group, state in states if group in groups and not state.startswith("Z")}


def signal_groups(groups, signum):
    for group in groups:
        try:
            os.killpg(group, signum)
        except ProcessLookupError:
            pass


def wait_for_groups(process, groups, seconds):
    deadline = time.monotonic() + seconds
    while True:
        process.poll()
        live = remember_groups(process, groups)
        if not live:
            process.wait()
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(.1)


def run_child(command, root, environment):
    process = subprocess.Popen(command, cwd=root, env=environment, start_new_session=True)
    groups = {process.pid}
    with cancellation_signals():
        try:
            while True:
                remember_groups(process, groups)
                try:
                    code = process.wait(timeout=1)
                    break
                except subprocess.TimeoutExpired:
                    pass
        except KeyboardInterrupt as error:
            # Let entry-point finally blocks and xcodebuild finalize private results first.
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            try:
                remember_groups(process, groups)
                signal_groups({process.pid}, signal.SIGINT)
                if not wait_for_groups(process, groups, INTERRUPT_GRACE_SECONDS):
                    signal_groups(groups, signal.SIGTERM)
                    if not wait_for_groups(process, groups, 15):
                        signal_groups(groups, signal.SIGKILL)
                        if not wait_for_groups(process, groups, 15):
                            raise SnapshotCleanupError("child process groups did not exit after cancellation")
            except (OSError, subprocess.SubprocessError) as cleanup_error:
                raise SnapshotCleanupError("child cleanup could not be verified") from cleanup_error
            return 128 + getattr(error, "signum", signal.SIGINT)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            signal_groups({process.pid}, signal.SIGINT)
            raise SnapshotCleanupError("child process state could not be verified") from error
        try:
            if not wait_for_groups(process, groups, 5):
                # Xcode can leave owned developer services holding the snapshot cwd.
                with ignored_cancellation_signals():
                    signal_groups(groups, signal.SIGINT)
                    if not wait_for_groups(process, groups, 15):
                        signal_groups(groups, signal.SIGTERM)
                        if not wait_for_groups(process, groups, 15):
                            signal_groups(groups, signal.SIGKILL)
                            if not wait_for_groups(process, groups, 15):
                                raise SnapshotCleanupError("entry point exited with live child process groups")
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            raise SnapshotCleanupError("child cleanup could not be verified") from error
        return code


def launch(script, arguments):
    root = script.resolve().parent.parent
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--strict-ci", action="store_true")
    parser.add_argument("--allow-private-config", action="store_true")
    parser.add_argument("--config", action="append", default=[])
    parser.add_argument("--snapshot-record", type=Path)
    options, remaining = parser.parse_known_args(arguments)
    mode = select_mode([flag for flag, enabled in (("--strict-ci", options.strict_ci),
                       ("--allow-private-config", options.allow_private_config)) if enabled])
    if script.name == "run_offline_unit_tests.py":
        if "--prepare-example-config" in remaining:
            # Setup may affect the caller's checkout, but must never start a build there.
            if any(argument not in {"--prepare-example-config", "--check"} for argument in remaining):
                raise ValueError("prepare local configuration separately before a CI-equivalent run")
            mode = "private"
    environment = clean_environment(os.environ, options.config)
    environment.pop(CONTEXT, None)
    environment.pop(MODE_CONTEXT, None)
    environment.pop(SOURCE_CONTEXT, None)
    remaining = absolute_paths(remaining, Path.cwd())
    for index, argument in enumerate(remaining):
        option, separator, inline = argument.partition("=")
        if option == "--project" and (separator or index + 1 < len(remaining)):
            project = (Path.cwd() / (inline if separator else remaining[index + 1])).resolve()
            if root not in project.parents:
                raise ValueError("--project must belong to the source checkout being snapshotted")
            relative = str(project.relative_to(root))
            if separator:
                remaining[index] = option + "=" + relative
            else:
                remaining[index + 1] = relative
    record_path = options.snapshot_record.resolve() if options.snapshot_record else None
    output_value = option_value(remaining, {"--output-dir", "--evidence-dir"})
    output = Path(output_value) if output_value else None
    if output and (output == root or root in output.parents):
        raise ValueError("output/evidence directory must be outside the source checkout")
    if RESULT_CHECK_COMMANDS.intersection(remaining):
        record_path = None
    elif record_path is None and output:
        record_path = output / "local-snapshot.json"
    if record_path and (record_path == root or root in record_path.parents):
        raise ValueError("snapshot record must be outside the source checkout")
    if record_path and os.path.lexists(record_path):
        raise ValueError("snapshot record must be fresh; refusing to overwrite an earlier receipt")

    def execute(checkout, receipt):
        environment[CONTEXT] = str(checkout.resolve())
        environment[MODE_CONTEXT] = receipt["mode"]
        environment[SOURCE_CONTEXT] = str(root)
        target = checkout / script.relative_to(root)
        child_arguments = list(remaining)
        if target.name == "run_offline_unit_tests.py" and option_value(child_arguments, {"--derived-data-path"}) is None:
            platform = option_value(child_arguments, {"--platform"}) or "local"
            child_arguments += ["--derived-data-path", str(root / (".derivedData/offline-" + platform))]
        command = (["bash", str(target)] if target.suffix == ".sh" else [sys.executable, "-B", str(target)]) + child_arguments
        print("Local mode: " + receipt["mode"] + "; tested tree: " + (receipt["tree_sha"] or "unrecorded (original checkout)"), flush=True)
        code = run_child(command, checkout, environment)
        if receipt["mode"] != "private" and (checkout.parent / "cleanup-failed").exists():
            raise SnapshotCleanupError("entry-point cleanup failed")
        return code

    def record_exit(receipt, code):
        receipt.update(exit_code=code, explicit_configuration_keys=[entry.partition("=")[0] for entry in options.config])
        if record_path:
            record_path.parent.mkdir(parents=True, exist_ok=True)
            record_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        return code

    receipt = None
    try:
        if mode == "private":
            receipt = {"schema_version": 1, "mode": "private", "source_commit_sha": git(root, "rev-parse", "HEAD"),
                       "tree_sha": None, "source_dirty": bool(git(root, "status", "--porcelain")),
                       "private_configuration": any(os.path.lexists(root / path) for path in PRIVATE_PATHS)}
            code = execute(root, receipt)
        else:
            with snapshot(root, strict=mode == "strict") as (checkout, receipt):
                code = execute(checkout, receipt)
    except KeyboardInterrupt as error:
        if receipt is not None:
            record_exit(receipt, 128 + getattr(error, "signum", signal.SIGINT))
        raise
    except (OSError, ValueError, subprocess.SubprocessError, SnapshotCleanupError):
        if receipt is not None:
            record_exit(receipt, 2)
        raise
    return record_exit(receipt, code)


def local_main(main, filename):
    script = Path(filename).resolve()
    root = script.parent.parent
    # Hosted producers retain their admitted identity and checkout contracts.
    hosted = os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
    nested = os.environ.get(CONTEXT) == str(root)
    if nested and os.environ.get(MODE_CONTEXT) != "private" and any(os.path.lexists(root / path) for path in PRIVATE_PATHS):
        nested = False
    if hosted or nested:
        with cancellation_signals():
            try:
                return main()
            except SnapshotCleanupError:
                if nested and os.environ.get(MODE_CONTEXT) != "private":
                    (root.parent / "cleanup-failed").touch()
                raise
    if "--help" in sys.argv or "-h" in sys.argv:
        print("Local defaults: isolated working-tree snapshot; no ambient/private configuration.\n"
              "  --strict-ci              Refuse a dirty working tree.\n"
              "  --allow-private-config   Explicitly use the caller's local configuration.\n"
              "  --config NAME=VALUE      Explicit runtime test configuration (repeatable).\n"
              "  --snapshot-record PATH   Keep the tested tree receipt outside the checkout.\n")
        return main()
    try:
        with cancellation_signals():
            return launch(script, sys.argv[1:])
    except KeyboardInterrupt as error:
        return 128 + getattr(error, "signum", signal.SIGINT)
    except (OSError, ValueError, subprocess.SubprocessError, SnapshotCleanupError) as error:
        print("Local preflight refused: " + (str(error) if isinstance(error, (ValueError, SnapshotCleanupError)) else type(error).__name__), file=sys.stderr)
        return 2


if __name__ == "__main__":
    try:
        with cancellation_signals():
            raise SystemExit(launch(Path(sys.argv[1]), sys.argv[2:]))
    except KeyboardInterrupt as error:
        raise SystemExit(128 + getattr(error, "signum", signal.SIGINT))
    except (OSError, ValueError, subprocess.SubprocessError, SnapshotCleanupError) as error:
        print("Local preflight refused: " + (str(error) if isinstance(error, (ValueError, SnapshotCleanupError)) else type(error).__name__), file=sys.stderr)
        raise SystemExit(2)
