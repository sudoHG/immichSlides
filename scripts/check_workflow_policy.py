#!/usr/bin/env python3
"""Check workflow pins and privilege boundaries without executing candidate code."""
from __future__ import annotations

import argparse
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml


PRIVACY_WORKFLOW = ".github/workflows/privacy-preflight.yml"
WORKFLOW_RUN_SOURCES = {
    ".github/workflows/ci-publish.yml": {"ci-gate", "ci-ui"},
    ".github/workflows/ci-report.yml": {"ci-nightly", "ci-gate"},
}
ENVIRONMENT_WORKFLOWS = {
    "ci-publisher": {".github/workflows/ci-publish.yml", ".github/workflows/ci-approval.yml",
                     ".github/workflows/ci-approve.yml"},
    "ci-approval": {".github/workflows/ci-approval.yml"},
    "release": {".github/workflows/ci-release.yml"},
}
TRUSTED_WORKFLOWS = {PRIVACY_WORKFLOW, ".github/workflows/ci-probe.yml"} | set(WORKFLOW_RUN_SOURCES)
for allowed in ENVIRONMENT_WORKFLOWS.values():
    TRUSTED_WORKFLOWS.update(allowed)

# New trusted interfaces require an explicit policy change and review.
TRUSTED_REMOTE_ACTION_INPUTS = {
    "actions/checkout": {"ref", "repository", "fetch-depth", "persist-credentials"},
    "actions/download-artifact": {"path", "name", "pattern", "run-id", "github-token", "repository",
                                  "artifact-ids", "merge-multiple"},
}
TRUSTED_READ_ONLY_COMMANDS = {("pwd",), ("git", "rev-parse", "HEAD")}
TRUSTED_PYTHON_COMMANDS = {
    ("/usr/bin/python3", "scripts/check_workflow_policy.py"),
    ("/usr/bin/python3", "scripts/check_workflow_policy.py", "--root", "."),
}
PRIVACY_ENVIRONMENT = {
    "PRIVACY_PR_NUMBER": "${{ github.event.pull_request.number }}",
    "PRIVACY_HEAD_SHA": "${{ github.event.pull_request.head.sha }}",
    "PRIVACY_BASE_SHA": "${{ github.event.pull_request.base.sha }}",
}
# Grandfather only this reviewed object-fetch block, without general shell parsing.
PRIVACY_OBJECT_FETCH = r'''case "$PRIVACY_PR_NUMBER" in
  *[!0-9]*|"") exit 3 ;;
esac
case "$PRIVACY_HEAD_SHA" in
  *[!0-9a-f]*|"") exit 3 ;;
esac
git fetch --no-tags --force origin \
  "refs/pull/${PRIVACY_PR_NUMBER}/head"
test "$(git rev-parse FETCH_HEAD)" = "$PRIVACY_HEAD_SHA"'''


class WorkflowLoader(yaml.SafeLoader):
    def compose_node(self, parent, index):
        if self.check_event(yaml.AliasEvent):
            raise yaml.YAMLError("YAML aliases are not allowed in workflows")
        return super().compose_node(parent, index)

    def construct_mapping(self, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if not isinstance(key, str) or key in mapping:
                raise yaml.YAMLError("Workflow mapping keys must be unique strings")
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


# GitHub's `on` must remain a string, rather than YAML 1.1's boolean True.
WorkflowLoader.yaml_implicit_resolvers = {
    key: [(tag, pattern) for tag, pattern in resolvers if tag != "tag:yaml.org,2002:bool"]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
WorkflowLoader.add_implicit_resolver("tag:yaml.org,2002:bool", re.compile(r"^(?:true|false)$", re.I), list("tTfF"))


@dataclass(frozen=True)
class Violation:
    path: str
    location: str
    rule: str
    message: str

    def __str__(self):
        return f"{self.path}:{self.location}: [{self.rule}] {self.message}"


def pinned_action(value):
    if not isinstance(value, str) or "${{" in value:
        return False
    if value.startswith("./"):
        return all(part not in {"..", ""} for part in value[2:].split("/"))
    if value.startswith("docker://"):
        return re.fullmatch(r"docker://[^\s@]+@sha256:[0-9a-f]{64}", value) is not None
    return re.fullmatch(r"[\w.-]+/[\w.-]+(?:/[\w./-]+)?@[0-9a-f]{40}", value) is not None


def explicit_permissions(value):
    return isinstance(value, dict) and all(isinstance(level, str) and level in {"read", "write", "none"}
                                          for level in value.values())


def walk_mappings(value, location="workflow"):
    if isinstance(value, dict):
        yield location, value
        for key, child in value.items():
            yield from walk_mappings(child, f"{location}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk_mappings(child, f"{location}[{index}]")


def artifact_path(value):
    if not isinstance(value, str):
        return False
    value = value.replace("${{ runner.temp }}", "/runner-temp")
    if ".." in value.split("/") or "$" in value:
        return False
    return re.fullmatch(r"(?:/runner-temp/)?ci-artifacts(?:/[\w.-]+)*", value) is not None


def trusted_run_allowed(script, path, events):
    if not isinstance(script, str):
        return False
    script = script.strip()
    if path == PRIVACY_WORKFLOW and set(events) == {"pull_request_target"}:
        if script in {PRIVACY_OBJECT_FETCH, "scripts/run_trusted_privacy_preflight.sh"}:
            return True
    # Only literal command tokens are considered; shell operators and expansion are never interpreted.
    if any(character in script for character in "<>|;&\n\r$`\\(){}*?[]"):
        return False
    try:
        command = tuple(shlex.split(script))
    except ValueError:
        return False
    return command in TRUSTED_READ_ONLY_COMMANDS or command in TRUSTED_PYTHON_COMMANDS


def trusted_run_settings_allowed(settings):
    return (isinstance(settings, dict) and set(settings) <= {"shell", "working-directory"}
            and settings.get("shell", "bash") in ("bash", "sh")
            and settings.get("working-directory", ".") == ".")


def trusted_action_allowed(uses, options):
    if not pinned_action(uses):
        return False
    if uses.startswith("./"):
        parts = uses[2:].split("/")
        return (uses.startswith("./.github/actions/") and not options
                and all(re.fullmatch(r"[\w.-]+", part) and part.casefold() not in
                        {"artifact", "artifacts", "ci-artifacts", "download", "downloads"} for part in parts))
    allowed_inputs = TRUSTED_REMOTE_ACTION_INPUTS.get(uses.split("@")[0].lower())
    return allowed_inputs is not None and set(options) <= allowed_inputs


def check_workflow(path: str, source: str) -> list[Violation]:
    violations = []

    def flag(location, rule, message):
        violations.append(Violation(path, location, rule, message))

    try:
        document = yaml.load(source, Loader=WorkflowLoader)
    except (yaml.YAMLError, ValueError, RecursionError):
        flag("workflow", "workflow-format", "Invalid, duplicate-key, aliased or unsupported YAML")
        return violations
    if not isinstance(document, dict):
        flag("workflow", "workflow-format", "Expected one workflow mapping")
        return violations
    event = document.get("on")
    if isinstance(event, str):
        events = {event: None}
    elif isinstance(event, list) and all(isinstance(item, str) for item in event):
        events = dict.fromkeys(event)
    elif isinstance(event, dict):
        events = event
    else:
        events = {}
    if not events:
        flag("on", "workflow-format", "Expected explicit workflow triggers")
    if "pull_request_target" in events and path != PRIVACY_WORKFLOW:
        flag("on", "pull-request-target", "Only the trusted privacy workflow may use pull_request_target")
    if "workflow_run" in events:
        configuration = events["workflow_run"]
        allowed = WORKFLOW_RUN_SOURCES.get(path, set())
        sources = configuration.get("workflows") if isinstance(configuration, dict) else None
        types = configuration.get("types", ["completed"]) if isinstance(configuration, dict) else None
        if (not allowed or not isinstance(sources, list) or not sources
                or any(not isinstance(name, str) or name not in allowed for name in sources)
                or not isinstance(types, list) or not types
                or any(kind not in ("requested", "in_progress", "completed") for kind in types)):
            flag("on.workflow_run", "workflow-run", "Only named trusted consumers and their explicit producers are allowed")
    jobs = document.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        flag("jobs", "workflow-format", "Expected at least one job")
        return violations
    if "permissions" in document and not explicit_permissions(document["permissions"]):
        flag("permissions", "permissions", "Use an explicit permission mapping, including {} for no grants")
    trusted = path in TRUSTED_WORKFLOWS or bool({"pull_request_target", "workflow_run"} & set(events))
    for job_id, job in jobs.items():
        location = f"jobs.{job_id}"
        if not isinstance(job, dict):
            flag(location, "workflow-format", "Expected a job mapping")
            continue
        permissions = job.get("permissions", document.get("permissions"))
        if not explicit_permissions(permissions):
            flag(location, "permissions", "Job needs explicit permissions, directly or inherited")
        timeout = job.get("timeout-minutes")
        if type(timeout) is not int or not 1 <= timeout <= 360:
            flag(location, "timeout", "Job needs a literal timeout-minutes from 1 to 360")
        if "environment" in job:
            environment = job["environment"]
            name = environment.get("name") if isinstance(environment, dict) else environment
            normalized_name = name.casefold() if isinstance(name, str) else None
            if (not isinstance(name, str) or "${{" in name
                    or (normalized_name in ENVIRONMENT_WORKFLOWS and path not in ENVIRONMENT_WORKFLOWS[normalized_name])):
                flag(location, "environment", "Protected environments are bound to named workflows; names must be literal")
        steps = job.get("steps")
        if "uses" not in job and (not isinstance(steps, list) or not steps):
            flag(location, "workflow-format", "Expected steps or a pinned reusable workflow")
        elif isinstance(steps, list) and any(not isinstance(step, dict) or not ("uses" in step or "run" in step) for step in steps):
            flag(location, "workflow-format", "Each step needs run or uses")
        if trusted and isinstance(steps, list):
            for index, step in enumerate(steps):
                if not isinstance(step, dict):
                    continue
                step_location = f"{location}.steps[{index}]"
                if "run" in step and not trusted_run_allowed(step["run"], path, events):
                    flag(step_location, "trusted-run", "Trusted run must be an allowlisted literal command or entry point")
                settings = {key: step[key] for key in ("shell", "working-directory") if key in step}
                if not trusted_run_settings_allowed(settings):
                    flag(step_location, "trusted-run", "Trusted commands require the default workspace and a reviewed shell")
        if trusted and any(key in job for key in ("container", "services")):
            flag(location, "trusted-run", "Trusted jobs cannot start unreviewed containers or services")
    for location, item in walk_mappings(document):
        if "uses" in item and not pinned_action(item["uses"]):
            flag(location, "action-pin", "Remote uses must have a full commit SHA; container actions need a sha256 digest")
        if not trusted:
            continue
        environment = item.get("env", {})
        loader_variables = {"PATH", "BASH_ENV", "ENV", "PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS",
                            "RUBYLIB", "PERL5LIB", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES"}
        if isinstance(environment, dict) and any(key in loader_variables for key in environment):
            flag(location, "artifact-execution", "Artifact data must not control executable search or interpreter startup")
        if (not isinstance(environment, dict) or any(path != PRIVACY_WORKFLOW
                or key not in PRIVACY_ENVIRONMENT or value != PRIVACY_ENVIRONMENT[key]
                for key, value in environment.items())):
            flag(location, "trusted-environment", "Trusted environment variables need an explicit reviewed binding")
        if "defaults" in item:
            defaults = item["defaults"]
            if (not isinstance(defaults, dict) or set(defaults) != {"run"}
                    or not trusted_run_settings_allowed(defaults["run"])):
                flag(location, "trusted-run", "Trusted run defaults cannot change the shell or workspace")
        uses = item.get("uses", "")
        options = item.get("with", {})
        if not isinstance(options, dict):
            flag(location, "workflow-format", "Action inputs must be a mapping")
            continue
        if "uses" in item and not trusted_action_allowed(uses, options):
            flag(location, "trusted-action", "Trusted uses must be an approved pinned remote action or isolated repository-local action")
        if isinstance(uses, str) and uses.split("@")[0].lower() == "actions/checkout":
            ref = options.get("ref")
            allowed_refs = {"main", "refs/heads/main", "${{ github.event.repository.default_branch }}"}
            if path == PRIVACY_WORKFLOW and set(events) == {"pull_request_target"}:
                allowed_refs.update({None, "${{ github.event.pull_request.base.sha }}"})
            repository = options.get("repository")
            if (not (ref is None or isinstance(ref, str)) or ref not in allowed_refs
                    or not (repository is None or isinstance(repository, str))
                    or repository not in {None, "${{ github.repository }}"}):
                flag(location, "trusted-checkout", "Trusted checkout must use this repository's default branch (privacy may use base.sha)")
        if isinstance(uses, str) and "download-artifact" in uses.lower() and not artifact_path(options.get("path")):
            flag(location, "artifact-execution", "Download artifact data only into an explicit ci-artifacts directory")
        if "script" in options:
            flag(location, "artifact-execution", "Trusted actions cannot execute inline scripts")
    return violations


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="Repository root (default: this script's repository)")
    args = parser.parse_args(argv)
    directory = args.root / ".github/workflows"
    paths = sorted(directory.glob("*.yml")) + sorted(directory.glob("*.yaml"))
    violations = []
    if not paths:
        print("Workflow policy FAIL: no workflows found", file=sys.stderr)
        return 1
    for path in paths:
        relative = path.relative_to(args.root).as_posix()
        try:
            if path.is_symlink():
                raise ValueError("Workflow symlinks are unsupported")
            violations.extend(check_workflow(relative, path.read_text(encoding="utf-8")))
        except (OSError, UnicodeError, ValueError):
            violations.append(Violation(relative, "workflow", "workflow-format", "Cannot read a regular UTF-8 workflow"))
    for violation in violations:
        print(violation, file=sys.stderr)
    print(f"Workflow policy {'FAIL' if violations else 'PASS'}: {len(paths)} workflows, {len(violations)} violations")
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
