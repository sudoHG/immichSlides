#!/usr/bin/env python3
"""Check workflow pins and privilege boundaries without executing candidate code."""
from __future__ import annotations

import argparse
import copy
import re
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml


PRIVACY_WORKFLOW = ".github/workflows/privacy-preflight.yml"
SHADOW_WORKFLOW = ".github/workflows/ci-smoke-shadow.yml"
SHADOW_PLAN_GUARD = ("github.ref == 'refs/heads/main' && "
    "(github.event_name == 'schedule' || github.event_name == 'workflow_dispatch')")
SHADOW_CONCURRENCY_GROUP = ("${{ (" + SHADOW_PLAN_GUARD + ") && "
    "'ci-smoke-shadow' || format('ci-smoke-shadow-rejected-{0}', github.run_id) }}")
SHADOW_BINDINGS = {"SMOKE_SCOPE": "${{ github.event_name == 'workflow_dispatch' && (inputs.scope || 'full') || 'core' }}",
                   "SMOKE_TOKEN": "${{ github.token }}",
                   "SMOKE_GROUP": "${{ matrix.id }}", "SMOKE_MATRIX_RESULT": "${{ needs.flows.result }}"}
SHADOW_CONFIGURATION = "${{ github.job == 'ios-debug' && 'Debug' || 'Release' }}"
SHADOW_BINDINGS.update(SMOKE_CONFIGURATION=SHADOW_CONFIGURATION, SMOKE_ARTIFACT_ID="${{ steps.archive.outputs.artifact-id }}")
for _configuration in ("debug", "release"):
    SHADOW_BINDINGS["SMOKE_" + _configuration.upper() + "_RESULT"] = "${{ needs.ios-" + _configuration + ".result }}"
    for _field in ("artifact_id", "manifest_sha256", "archive_sha256"):
        SHADOW_BINDINGS["SMOKE_" + _configuration.upper() + "_" + _field.upper()] = "${{ needs.ios-" + _configuration + ".outputs." + _field + " }}"
SHADOW_SETUP = "/usr/bin/python3 -B scripts/ci_smoke_shadow.py setup"
SHADOW_STAGE = "/usr/bin/python3 -B scripts/ci_smoke_shadow.py stage"
SHADOW_STAGED_SETUP = '/usr/bin/python3 -B "$RUNNER_TEMP/smoke-control/ci_smoke_shadow.py" setup'
SHADOW_COMMAND = '"$RUNNER_TEMP/smoke-python/bin/python3" -B scripts/ci_smoke_shadow.py '
SHADOW_GROUP_COMMAND = '"$RUNNER_TEMP/smoke-python/bin/python3" -B "$RUNNER_TEMP/smoke-control/ci_smoke_shadow.py" '
WORKFLOW_RUN_SOURCES = {}
# Main pushes share one first-attempt queue (superseding only pending runs); pull requests cancel
# within their own PR; reruns and nightly runs get a group of their own and are never cancelled.
CANCEL_PULL_REQUESTS_ONLY = "${{ github.event_name == 'pull_request' }}"
CONCURRENCY_WORKFLOWS = {
    ".github/workflows/ci-gate.yml": {
        "group": "ci-gate-${{ github.event_name }}-${{ github.event.pull_request.number || "
                 "(github.event_name == 'push' && github.run_attempt == 1 && 'main') || github.run_id }}",
        "cancel-in-progress": CANCEL_PULL_REQUESTS_ONLY},
}

TRUSTED_WORKFLOWS = {PRIVACY_WORKFLOW, SHADOW_WORKFLOW}

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


def string_scalars(value, location='workflow'):
    if isinstance(value, str):
        yield location, value
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from string_scalars(child, f'{location}.{key}')
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from string_scalars(child, f'{location}[{index}]')


STRING_LITERAL = re.compile(r"'(?:[^']|'')*'")
EXPRESSION = re.compile(r"\$\{\{((?:" + STRING_LITERAL.pattern + r"|[^']|')*?)(?:\}\}|\Z)")
SECRETS_ROOT = r"(?<![\w-])secrets(?![\w-])"


def implicit_expression_locations(jobs):
    """Locations of the job-level and step-level `if:` keys, whose values are expressions without `${{ }}`."""
    locations = set()
    for job_id, job in jobs.items():
        if isinstance(job, dict):
            locations.add(f'workflow.jobs.{job_id}.if')
            steps = job.get('steps')
            locations.update(f'workflow.jobs.{job_id}.steps[{index}].if' for index in range(len(steps) if isinstance(steps, list) else 0))
    return locations


def expression_code(location, value, implicit_locations, *, keep_index_literals=False):
    """Expression source of a scalar. String literals are blanked, except index keys like secrets['NAME'] when asked."""
    bodies = [value] if location in implicit_locations else EXPRESSION.findall(value)

    def blank(match):
        keep = keep_index_literals and match.string[:match.start()].rstrip().endswith('[')
        return match.group(0) if keep else "''"
    return [STRING_LITERAL.sub(blank, body) for body in bodies]


def names_secrets_root(code, pattern=SECRETS_ROOT):
    """The secrets context is the identifier itself, not a property (a.secrets) or a longer name (check-secrets)."""
    return any(code[:match.start()].rstrip()[-1:] != '.' for match in re.finditer(pattern, code, re.IGNORECASE))


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
    if path == SHADOW_WORKFLOW and set(events) == {"schedule", "workflow_dispatch"}:
        return script in {SHADOW_SETUP, SHADOW_STAGE, SHADOW_STAGED_SETUP, SHADOW_COMMAND + "plan", SHADOW_COMMAND + "plan-shared",
                          SHADOW_COMMAND + "aggregate", SHADOW_GROUP_COMMAND + "build", SHADOW_GROUP_COMMAND + "producer-record",
                          SHADOW_GROUP_COMMAND + "select-archive", SHADOW_GROUP_COMMAND + "run", SHADOW_GROUP_COMMAND + "cleanup"}
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


def shadow_artifact_allowed(item):
    uses, options = item.get("uses", ""), item.get("with", {})
    if not isinstance(uses, str):
        return False
    suffix = "-${{ github.run_id }}-${{ github.run_attempt }}"
    if uses == "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093":
        return options in (
            {"name": "smoke-shadow-plan" + suffix, "path": "${{ runner.temp }}/ci-artifacts/smoke-plan"},
            {"pattern": "smoke-shadow-group-*" + suffix, "path": "${{ runner.temp }}/ci-artifacts/smoke-groups"},
            {"pattern": "smoke-shadow-producer-*" + suffix, "path": "${{ runner.temp }}/ci-artifacts/smoke-producers"},
            {"artifact-ids": "${{ steps.select.outputs.artifact_id }}", "path": "${{ runner.temp }}/ci-artifacts/smoke-build",
             "merge-multiple": True, "github-token": "${{ github.token }}", "repository": "${{ github.repository }}", "run-id": "${{ github.run_id }}"})
    if uses != "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02":
        return False
    if (options == {"name": "${{ steps.build.outputs.artifact_name }}", "path": "${{ runner.temp }}/smoke-producer/output/archive",
                    "retention-days": 1, "compression-level": 0, "if-no-files-found": "error"}
            and item.get("if") == "steps.build.outputs.archive_safe == 'true'"):
        return True
    return any(options == {"retention-days": retention, "if-no-files-found": "error", "name": name + suffix,
                           "path": "${{ runner.temp }}/" + path}
               and item.get("if") == guard for name, path, guard, retention in (
                   ("smoke-shadow-plan", "smoke-plan/plan.json", "steps.plan.outputs.records_safe == 'true'", 7),
                   ("smoke-shadow-group-${{ matrix.id }}", "smoke-records", "always() && steps.run.outputs.records_safe == 'true'", 7),
                   ("smoke-shadow-producer-${{ github.job }}", "smoke-producer-records", "always() && steps.record.outputs.records_safe == 'true'", 7),
                   ("smoke-shadow", "smoke-shadow", "always() && steps.aggregate.outputs.records_safe == 'true'", 90)))


def check_shared_shadow_contract(document, events, flag):
    """Validate the added graph, then preserve every original shadow rule on its projection."""
    jobs = document["jobs"]
    projected = copy.deepcopy(document)
    valid = set(jobs) == {"plan", "ios-debug", "ios-release", "flows", "aggregate"}
    try:
        upload = "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
        download = "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"
        checkout = "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
        suffix = "-${{ github.run_id }}-${{ github.run_attempt }}"
        guard = "${{ !cancelled() && needs.plan.result == 'success' && needs.plan.outputs.execute == 'true' }}"
        def plain(step):
            return {key: value for key, value in step.items() if key != "name"}
        prefix = [{"uses": checkout, "with": {"ref": "${{ needs.plan.outputs.control_sha }}", "fetch-depth": 0, "persist-credentials": False}},
                  {"run": SHADOW_STAGE},
                  {"uses": checkout, "with": {"ref": "${{ needs.plan.outputs.head_sha }}", "fetch-depth": 0, "persist-credentials": False}},
                  {"run": SHADOW_STAGED_SETUP},
                  {"uses": download, "with": {"name": "smoke-shadow-plan" + suffix,
                                              "path": "${{ runner.temp }}/ci-artifacts/smoke-plan"}}]
        config_env = {"SMOKE_CONFIGURATION": SHADOW_CONFIGURATION}
        build_env = dict(config_env, SMOKE_TOKEN=SHADOW_BINDINGS["SMOKE_TOKEN"])
        for role in ("ios-debug", "ios-release"):
            job = jobs[role]
            valid &= (set(job) == {"needs", "if", "name", "runs-on", "timeout-minutes", "permissions", "outputs", "steps"}
                      and job["needs"] == "plan"
                      and job["if"] == guard.replace("outputs.execute", "outputs." + role.replace("-", "_"))
                      and job["name"] == "smoke-shadow-" + role
                      and job["runs-on"] == "xcode-27" and job["timeout-minutes"] == 30
                      and job["permissions"] == {"contents": "read", "actions": "read"}
                      and job["outputs"] == {"artifact_id": "${{ steps.archive.outputs.artifact-id }}",
                           "manifest_sha256": "${{ steps.build.outputs.manifest_sha256 }}",
                           "archive_sha256": "${{ steps.build.outputs.archive_sha256 }}"})
            steps = job["steps"]
            expected = prefix + [
                {"id": "build", "env": build_env, "run": SHADOW_GROUP_COMMAND + "build"},
                {"id": "archive", "if": "steps.build.outputs.archive_safe == 'true'", "uses": upload,
                 "with": {"name": "${{ steps.build.outputs.artifact_name }}", "path": "${{ runner.temp }}/smoke-producer/output/archive",
                          "retention-days": 1, "compression-level": 0, "if-no-files-found": "error"}},
                {"id": "record", "if": "always()", "env": dict(build_env, SMOKE_ARTIFACT_ID=SHADOW_BINDINGS["SMOKE_ARTIFACT_ID"]),
                 "run": SHADOW_GROUP_COMMAND + "producer-record"},
                {"if": "always() && steps.record.outputs.records_safe == 'true'", "uses": upload,
                 "with": {"name": "smoke-shadow-producer-${{ github.job }}" + suffix, "path": "${{ runner.temp }}/smoke-producer-records",
                          "retention-days": 7, "if-no-files-found": "error"}},
                {"if": "always()", "env": config_env, "run": SHADOW_GROUP_COMMAND + "cleanup"}]
            valid &= ([plain(step) for step in steps] == expected
                      and steps[5].get("name") == "Build the generic smoke configuration"
                      and steps[6].get("name") == "Publish the immutable configuration archive")
            projected["jobs"].pop(role)
        plan_steps = jobs["plan"]["steps"]
        valid &= len(plan_steps) == 4 and plan_steps[2].get("run") == SHADOW_COMMAND + "plan-shared"
        valid &= jobs["plan"]["outputs"] == {key: "${{ steps.plan.outputs." + key + " }}" for key in
                                              ("matrix", "head_sha", "control_sha", "execute", "ios_debug", "ios_release")}
        for key in ("control_sha", "ios_debug", "ios_release"):
            projected["jobs"]["plan"]["outputs"].pop(key)
        projected["jobs"]["plan"]["steps"][2]["run"] = SHADOW_COMMAND + "plan"
        flows = jobs["flows"]
        steps = flows["steps"]
        flow_prefix = copy.deepcopy(prefix)
        flow_prefix[3]["id"] = "setup"
        selection_env = {key: value for key, value in SHADOW_BINDINGS.items()
                         if key in {"SMOKE_GROUP", "SMOKE_TOKEN"} or any(key == "SMOKE_" + config + "_" + field
                            for config in ("DEBUG", "RELEASE") for field in ("ARTIFACT_ID", "MANIFEST_SHA256", "ARCHIVE_SHA256"))}
        valid &= (flows["needs"] == ["plan", "ios-debug", "ios-release"]
                  and flows["if"] == guard
                  and len(steps) == 10 and [plain(step) for step in steps[:5]] == flow_prefix
                  and plain(steps[5]) == {"id": "select", "if": "matrix.platform == 'ios'", "env": selection_env,
                                          "run": SHADOW_GROUP_COMMAND + "select-archive"}
                  and steps[6].get("name") == "Download the selected configuration archive"
                  and plain(steps[6]) == {"if": "matrix.platform == 'ios'", "uses": download,
                        "with": {"artifact-ids": "${{ steps.select.outputs.artifact_id }}", "path": "${{ runner.temp }}/ci-artifacts/smoke-build",
                                 "merge-multiple": True, "github-token": "${{ github.token }}", "repository": "${{ github.repository }}", "run-id": "${{ github.run_id }}"}}
                  and steps[7].get("if") == "${{ !cancelled() && steps.setup.outcome == 'success' }}"
                  and steps[8].get("uses") == upload and shadow_artifact_allowed(steps[8]))
        projected["jobs"]["flows"].update(needs="plan", **{"if": guard})
        projected["jobs"]["flows"]["steps"][0]["with"]["ref"] = "main"
        projected["jobs"]["flows"]["steps"][3].pop("id")
        projected["jobs"]["flows"]["steps"][7].pop("if")
        del projected["jobs"]["flows"]["steps"][5:7]
        aggregate = jobs["aggregate"]
        valid &= (aggregate["needs"] == ["plan", "ios-debug", "ios-release", "flows"] and len(aggregate["steps"]) == 7
                  and aggregate["permissions"] == {"contents": "read", "actions": "read"}
                  and aggregate["steps"][0].get("with") == {"ref": "${{ needs.plan.outputs.control_sha }}",
                                                                          "fetch-depth": 0, "persist-credentials": False}
                  and plain(aggregate["steps"][4]) == {"if": "always() && needs.plan.outputs.execute == 'true'", "uses": download,
                        "with": {"pattern": "smoke-shadow-producer-*" + suffix, "path": "${{ runner.temp }}/ci-artifacts/smoke-producers"}}
                  and aggregate["steps"][5].get("env") == {key: SHADOW_BINDINGS[key] for key in
                        ("SMOKE_MATRIX_RESULT", "SMOKE_DEBUG_RESULT", "SMOKE_RELEASE_RESULT", "SMOKE_TOKEN")})
        projected["jobs"]["aggregate"]["needs"] = ["plan", "flows"]
        projected["jobs"]["aggregate"]["permissions"] = {"contents": "read"}
        projected["jobs"]["aggregate"]["steps"][0]["with"]["ref"] = "main"
        del projected["jobs"]["aggregate"]["steps"][4]
        projected["jobs"]["aggregate"]["steps"][4]["env"] = {"SMOKE_MATRIX_RESULT": SHADOW_BINDINGS["SMOKE_MATRIX_RESULT"]}
    except (KeyError, TypeError, IndexError, AttributeError):
        valid = False
    if not valid:
        flag("workflow", "smoke-shadow-contract", "Shared shadow requires two 27/30-minute producers, immutable configuration downloads, verification, read-only provenance and always aggregation; capacity is 100 minutes / 230 runner minutes")
    else:
        check_shadow_contract(projected, events, flag)


def check_shadow_contract(document, events, flag):
    if any(role in document["jobs"] for role in ("ios-debug", "ios-release")):
        return check_shared_shadow_contract(document, events, flag)
    expected_events = {"schedule": [{"cron": "7 14 * * *"}, {"cron": "7 19 * * *"}],
        "workflow_dispatch": {"inputs": {"scope": {"description": "Smoke flow scope", "required": True,
            "default": "full", "type": "choice", "options": ["core", "full"]}}}}
    jobs = document["jobs"]
    concurrency = document.get("concurrency", {})
    valid = (document.get("name") == "ci-smoke-shadow" and events == expected_events
             and document.get("permissions") == {} and not document.get("env")
             and isinstance(concurrency, dict) and set(concurrency) == {"group", "cancel-in-progress"}
             and " ".join(str(concurrency.get("group", "")).split()) == SHADOW_CONCURRENCY_GROUP
             and concurrency.get("cancel-in-progress") is False
             and set(jobs) == {"plan", "flows", "aggregate"})
    conditions = {"plan": SHADOW_PLAN_GUARD,
                  "flows": "${{ !cancelled() && needs.plan.result == 'success' && needs.plan.outputs.execute == 'true' }}",
                  "aggregate": "${{ always() && github.ref == 'refs/heads/main' && needs.plan.result == 'success' }}"}
    for role, job in jobs.items():
        if role not in conditions or not isinstance(job, dict):
            valid = False
            continue
        steps = job.get("steps", [])
        valid &= (job.get("runs-on") == ("xcode-27" if role == "flows" else "ubuntu-24.04")
                  and job.get("timeout-minutes") == ("${{ matrix.timeout_minutes }}" if role == "flows" else 5)
                  and job.get("permissions") == ({"contents": "read", "actions": "read"} if role in {"plan", "flows"} else {"contents": "read"})
                  and " ".join(str(job.get("if", "")).split()) == conditions[role]
                  and "continue-on-error" not in job and "environment" not in job and not job.get("env")
                  and job.get("needs") == ({"flows": "plan", "aggregate": ["plan", "flows"]}.get(role))
                  and isinstance(steps, list) and not any("continue-on-error" in step for step in steps if isinstance(step, dict)))
        if role == "flows":
            valid &= job.get("strategy") == {"fail-fast": False, "max-parallel": 3,
                                             "matrix": "${{ fromJSON(needs.plan.outputs.matrix) }}"}
        if role == "plan":
            valid &= steps[0].get("with") == {"ref": "${{ github.sha }}", "fetch-depth": 0, "persist-credentials": False}
            valid &= job.get("outputs") == {key: "${{ steps.plan.outputs." + key + " }}" for key in ("matrix", "head_sha", "execute")}
        phase = "run" if role == "flows" else role
        runs = [step for step in steps if isinstance(step, dict) and "run" in step]
        expected_runs = ([SHADOW_STAGE, SHADOW_STAGED_SETUP, SHADOW_GROUP_COMMAND + "run", SHADOW_GROUP_COMMAND + "cleanup"]
                         if role == "flows" else [SHADOW_SETUP, SHADOW_COMMAND + phase])
        valid &= [step["run"] for step in runs] == expected_runs
        index = 2 if role == "flows" else 1
        if len(runs) > index:
            expected_environment = ({"SMOKE_SCOPE": SHADOW_BINDINGS["SMOKE_SCOPE"],
                                     "SMOKE_TOKEN": SHADOW_BINDINGS["SMOKE_TOKEN"]} if role == "plan" else
                                    {"SMOKE_GROUP": SHADOW_BINDINGS["SMOKE_GROUP"], "SMOKE_TOKEN": SHADOW_BINDINGS["SMOKE_TOKEN"]}
                                    if role == "flows" else {"SMOKE_MATRIX_RESULT": SHADOW_BINDINGS["SMOKE_MATRIX_RESULT"]})
            valid &= (all(step.get("if") is None for step in runs[:index]) and runs[index].get("id") == phase
                      and all(not step.get("env") for offset, step in enumerate(runs) if offset != index)
                      and runs[index].get("env") == expected_environment
                      and runs[index].get("if") == ("always()" if role == "aggregate" else None))
        if role == "flows" and runs:
            valid &= runs[-1].get("if") == "always()"
    if not valid:
        flag("workflow", "smoke-shadow-contract", "Smoke keeps main-only scheduled/manual admission, manifest groups, read-only authority and a 70-minute execution budget")


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
    if path == SHADOW_WORKFLOW:
        check_shadow_contract(document, events, flag)
    if "permissions" in document and not explicit_permissions(document["permissions"]):
        flag("permissions", "permissions", "Use an explicit permission mapping, including {} for no grants")
    if path in CONCURRENCY_WORKFLOWS and document.get("concurrency") != CONCURRENCY_WORKFLOWS[path]:
        flag("concurrency", "concurrency-queue", "Producer concurrency is fixed: main pushes supersede only pending main runs, "
             "reruns and nightly runs are never cancelled, and only pull requests cancel in progress")
    for location, value in string_scalars(document):
        if any(names_secrets_root(code) for code in expression_code(location, value,
                implicit_expression_locations(jobs), keep_index_literals=True)):
            flag(location, "credential", "Retained workflows cannot read repository secrets")
    implicit_locations = implicit_expression_locations(jobs)
    trusted = path in TRUSTED_WORKFLOWS or bool({"pull_request_target", "workflow_run"} & set(events))
    for job_id, job in jobs.items():
        location = f"jobs.{job_id}"
        if not isinstance(job, dict):
            flag(location, "workflow-format", "Expected a job mapping")
            continue
        if path in CONCURRENCY_WORKFLOWS and "concurrency" in job:
            flag(location, "concurrency-queue", "Producer jobs cannot override the workflow concurrency contract")
        permissions = job.get("permissions", document.get("permissions"))
        if not explicit_permissions(permissions):
            flag(location, "permissions", "Job needs explicit permissions, directly or inherited")
        if (any(label in str(job.get("runs-on", "")) for label in ("macos-", "xcode-"))
                and any(re.search(r"\balways\s*\(", code, re.IGNORECASE) for code in expression_code("workflow." + location + ".if", str(job.get("if", "")), implicit_locations))):
            flag(location, "macos-cancellation", "macOS jobs must stop on cancellation; never use job-level always()")
        timeout = job.get("timeout-minutes")
        shadow_matrix_timeout = (path == SHADOW_WORKFLOW and job_id == "flows"
                                 and timeout == "${{ matrix.timeout_minutes }}")
        if not shadow_matrix_timeout and (type(timeout) is not int or not 1 <= timeout <= 360):
            flag(location, "timeout", "Job needs a literal timeout-minutes from 1 to 360")
        if "environment" in job:
            flag(location, "environment", "Retained workflows cannot declare job environments")
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
        permissions = item.get("permissions")
        if isinstance(permissions, dict) and any(value == "write" for value in permissions.values()):
            flag(location, "write-permission", "Retained workflows require read-only permissions")
        if "uses" in item and not pinned_action(item["uses"]):
            flag(location, "action-pin", "Remote uses must have a full commit SHA; container actions need a sha256 digest")
        if not trusted:
            continue
        environment = item.get("env", {})
        loader_variables = {"PATH", "BASH_ENV", "ENV", "PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS",
                            "RUBYLIB", "PERL5LIB", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES"}
        if isinstance(environment, dict) and any(key in loader_variables for key in environment):
            flag(location, "artifact-execution", "Artifact data must not control executable search or interpreter startup")
        bindings = PRIVACY_ENVIRONMENT if path == PRIVACY_WORKFLOW else SHADOW_BINDINGS if path == SHADOW_WORKFLOW else {}
        if (not isinstance(environment, dict) or any(key not in bindings or value != bindings[key]
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
        shadow_artifact = path == SHADOW_WORKFLOW and shadow_artifact_allowed(item)
        shadow_bad_artifact = (path == SHADOW_WORKFLOW and isinstance(uses, str)
                               and uses.split("@")[0].lower() in {"actions/download-artifact", "actions/upload-artifact"}
                               and not shadow_artifact)
        if "uses" in item and (shadow_bad_artifact or not shadow_artifact and not trusted_action_allowed(uses, options)):
            flag(location, "trusted-action", "Trusted uses must be an approved pinned remote action or isolated repository-local action")
        if isinstance(uses, str) and uses.split("@")[0].lower() == "actions/checkout":
            ref = options.get("ref")
            allowed_refs = {"main", "refs/heads/main", "${{ github.event.repository.default_branch }}"}
            shadow_plan_checkout = path == SHADOW_WORKFLOW and location == "workflow.jobs.plan.steps[0]"
            if shadow_plan_checkout:
                allowed_refs.add("${{ github.sha }}")
            shadow_tested_checkout = (path == SHADOW_WORKFLOW and location in {
                "workflow.jobs." + role + ".steps[2]" for role in ("flows", "ios-debug", "ios-release")})
            if shadow_tested_checkout:
                allowed_refs.add("${{ needs.plan.outputs.head_sha }}")
            shadow_control_checkout = (path == SHADOW_WORKFLOW and any(
                role in document["jobs"] for role in ("ios-debug", "ios-release"))
                and location in {"workflow.jobs." + role + ".steps[0]" for role in
                                 ("ios-debug", "ios-release", "flows", "aggregate")})
            if shadow_control_checkout:
                allowed_refs.add("${{ needs.plan.outputs.control_sha }}")
            if path == PRIVACY_WORKFLOW and set(events) == {"pull_request_target"}:
                allowed_refs.update({None, "${{ github.event.pull_request.base.sha }}"})
            repository = options.get("repository")
            if (not (ref is None or isinstance(ref, str)) or ref not in allowed_refs
                    or not (repository is None or isinstance(repository, str))
                    or repository not in {None, "${{ github.repository }}"}):
                flag(location, "trusted-checkout", "Trusted checkout must use this repository's default branch (privacy may use base.sha)")
            if path == SHADOW_WORKFLOW and options != {
                    "ref": "${{ needs.plan.outputs.head_sha }}" if shadow_tested_checkout else
                           "${{ needs.plan.outputs.control_sha }}" if shadow_control_checkout else
                           "${{ github.sha }}" if shadow_plan_checkout else "main",
                    "fetch-depth": 0, "persist-credentials": False}:
                flag(location, "trusted-checkout", "Shadow executes only the plan-admitted main ancestor, with full history and no stored token")
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
    from ci_population import python_identities, python_sources
    from run_host_checks import MACOS_PYTHON_TESTS
    try:
        python_identities(python_sources(args.root / "scripts"), macos_python_tests=MACOS_PYTHON_TESTS)
    except (OSError, UnicodeError, ValueError) as error:
        violations.append(Violation("scripts/run_host_checks.py", "inventory", "macos-python-tests", str(error)))
    workflow_sources = {}
    for path in paths:
        relative = path.relative_to(args.root).as_posix()
        try:
            if path.is_symlink():
                raise ValueError("Workflow symlinks are unsupported")
            source = path.read_text(encoding="utf-8")
            workflow_sources[relative] = source
        except (OSError, UnicodeError, ValueError):
            violations.append(Violation(relative, "workflow", "workflow-format", "Cannot read a regular UTF-8 workflow"))
    for relative, source in workflow_sources.items():
        violations.extend(check_workflow(relative, source))
    for violation in violations:
        print(violation, file=sys.stderr)
    print(f"Workflow policy {'FAIL' if violations else 'PASS'}: {len(paths)} workflows, {len(violations)} violations")
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
