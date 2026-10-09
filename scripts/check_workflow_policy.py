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
PROBE_WORKFLOW = ".github/workflows/ci-probe.yml"
REPORT_WORKFLOW = ".github/workflows/ci-report.yml"
XCC_IMPORT_WORKFLOW = ".github/workflows/ci-xcode-cloud-import.yml"
XCC_ROUTE_WORKFLOW = ".github/workflows/ci-xcode-cloud-route.yml"
XCC_DISPATCH_WORKFLOW = ".github/workflows/ci-xcode-cloud-dispatch.yml"
XCC_WORKFLOWS = {XCC_IMPORT_WORKFLOW, XCC_ROUTE_WORKFLOW}
XCC_DISPATCH_GUARD = ("github.ref == 'refs/heads/main' && "
                      "github.event.workflow_run.head_repository.full_name == github.repository")
XCC_BINDINGS = {"CI_WORKFLOW_TOKEN": "${{ github.token }}",
                "ASC_ISSUER_ID": "${{ secrets.ASC_ISSUER_ID }}",
                "ASC_KEY_ID": "${{ secrets.ASC_KEY_ID }}",
                "ASC_PRIVATE_KEY": "${{ secrets.ASC_PRIVATE_KEY }}"}
XCC_CONTROL_BINDINGS = {**XCC_BINDINGS, "CI_XCC_ROUTING_OVERRIDE": "${{ vars.CI_XCC_ROUTING_OVERRIDE }}"}
LIVE_WORKFLOW = ".github/workflows/ci-nightly.yml"
LIVE_ENVIRONMENT = "immich-test-server"
LIVE_BINDINGS = {"CI_LIVE_URL": "${{ secrets.IMMICH_TEST_SERVER_URL }}",
                 "CI_LIVE_KEY": "${{ secrets.IMMICH_TEST_SERVER_API_KEY }}"}
ISSUE_WRITE_WORKFLOWS = {PROBE_WORKFLOW, ".github/workflows/ci-report.yml"}
PROBE_COMMANDS = {
    '/usr/bin/python3 scripts/setup_ci_python.py --python /usr/bin/python3 --venv "$RUNNER_TEMP/ci-python"',
    "/usr/bin/python3 scripts/probe_ci_toolchain.py",
}
PROBE_ENVIRONMENT = {
    "CI_PROBE_TOKEN": "${{ github.token }}",
    "CI_PROBE_SIMULATE_MISSING_PIN": "${{ inputs.simulate_missing_pin || false }}",
}
WORKFLOW_RUN_SOURCES = {
    XCC_DISPATCH_WORKFLOW: {"ci-ui", "ci-xcode-cloud-route"},
    ".github/workflows/ci-publish.yml": {"ci-gate", "ci-ui"},
    REPORT_WORKFLOW: {"ci-nightly", "ci-gate", "ci-ui"},
}
ENVIRONMENT_WORKFLOWS = {
    "xcode-cloud": XCC_WORKFLOWS,
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
PUBLISHER_COMMANDS = {
    ".github/workflows/ci-publish.yml": {"route", "admit", "reevaluate", "publish"},
    ".github/workflows/ci-approval.yml": {"approve"},
    ".github/workflows/ci-approve.yml": {"fallback"},
}
PUBLISHER_BINDINGS = {
    "CI_WORKFLOW_TOKEN": "${{ github.token }}",
    "CI_APP_ID": "${{ vars.CI_APP_ID }}",
    "CI_APP_PRIVATE_KEY": "${{ secrets.CI_APP_PRIVATE_KEY }}",
    "CI_PR_NUMBER": "${{ needs.route.outputs.pr }}",
    "CI_PUSHED_SHA": "${{ needs.route.outputs.pushed }}",
}
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
LIVE_SECRET_REFERENCE = SECRETS_ROOT + r"\s*(?:\.\s*IMMICH_TEST_SERVER_|\[\s*'IMMICH_TEST_SERVER_)"


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
    if path == XCC_DISPATCH_WORKFLOW and set(events) == {"workflow_run"}:
        if script in {'"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_xcode_cloud_dispatch.py',
                      '/usr/bin/python3 scripts/setup_ci_publisher_python.py --venv "$RUNNER_TEMP/ci-python"'}:
            return True
    if path in XCC_WORKFLOWS and set(events) == {"workflow_dispatch"}:
        role = "import" if path == XCC_IMPORT_WORKFLOW else "route"
        entries = ({'"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_xcode_cloud_import.py'} if role == "import" else
                   {'"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_xcode_cloud_route.py ' + phase for phase in ("prepare", "start", "poll")})
        if script in entries | {'/usr/bin/python3 scripts/setup_ci_publisher_python.py --venv "$RUNNER_TEMP/ci-python"'}:
            return True
    if path == REPORT_WORKFLOW and set(events) <= {"schedule", "workflow_dispatch", "workflow_run"}:
        if script in {'"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_report.py --phase collect',
                      '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_report.py --phase sync',
                      '/usr/bin/python3 scripts/setup_ci_publisher_python.py --venv "$RUNNER_TEMP/ci-python"'}:
            return True
    if path in PUBLISHER_COMMANDS:
        commands = {'"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_publish.py ' + command
                    for command in PUBLISHER_COMMANDS[path]}
        commands.add('/usr/bin/python3 scripts/setup_ci_publisher_python.py --venv "$RUNNER_TEMP/ci-python"')
        if path == ".github/workflows/ci-approval.yml":
            commands.add("/usr/bin/true")
        if script in commands:
            return True
    if path == PROBE_WORKFLOW and set(events) <= {"schedule", "workflow_dispatch"} and events:
        if script in PROBE_COMMANDS:
            return True
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
    if path == PROBE_WORKFLOW and (document.get("name") != "ci-probe"
            or set(events) != {"schedule", "workflow_dispatch"}
            or document.get("permissions") != {}):
        flag("workflow", "probe-contract", "ci-probe needs its exact name, scheduled/manual triggers and no workflow-level grants")
    approval_workflow = path in {".github/workflows/ci-approval.yml", ".github/workflows/ci-approve.yml"}
    if path == REPORT_WORKFLOW and (document.get("name") != "ci-report"
            or set(events) != {"schedule", "workflow_dispatch", "workflow_run"}
            or not isinstance(events.get("workflow_run"), dict)
            or events.get("workflow_run", {}).get("branches") != ["main"]
            or events.get("workflow_dispatch") != {"inputs": {"reset_history": {
                "description": "Maintainer-only explicit bootstrap or reset of reporting history",
                "required": False, "default": False, "type": "boolean"}, "health_month": {
                "description": "Optional UTC health month (YYYY-MM); scheduled collection reports the previous month on day 1",
                "required": False, "default": "", "type": "string"}}}
            or document.get("permissions") != {}):
        flag("workflow", "report-contract", "ci-report needs main-filtered completion/daily/manual triggers and no workflow-level grants")
    if approval_workflow and "concurrency" in document:
        flag("workflow", "approval-queue", "Approval records cannot enter a replaceable concurrency queue")
    if path == XCC_IMPORT_WORKFLOW and (document.get("name") != "ci-xcode-cloud-import"
            or document.get("run-name") != "xcc-import-${{ inputs.producer_run_id }}-${{ inputs.producer_attempt }}"
            or set(events) != {"workflow_dispatch"} or document.get("permissions") != {}
            or events["workflow_dispatch"] != {"inputs": {"producer_run_id": {
                "description": "Authoritative same-repository pull-request ci-ui run", "required": True, "type": "string"},
                "producer_attempt": {"description": "UI archive evidence attempt", "required": True, "type": "string"}}}):
        flag("workflow", "xcc-contract", "Cloud import accepts only a literal main-only dispatch interface")
    if path == XCC_ROUTE_WORKFLOW and (document.get("name") != "ci-xcode-cloud-route"
            or document.get("run-name") != "xcc-route-${{ inputs.producer_run_id }}-${{ inputs.producer_attempt }}"
            or set(events) != {"workflow_dispatch"} or document.get("permissions") != {}
            or "concurrency" in document or set(jobs) != {"start", "route"}
            or events["workflow_dispatch"] != {"inputs": {"producer_run_id": {
                "description": "Authoritative same-repository pull-request ci-ui run", "required": True, "type": "string"},
                "producer_attempt": {"description": "UI archive evidence attempt", "required": True, "type": "string"},
                "mode": {"description": "Routing policy or bounded fallback diagnostic", "required": True, "default": "auto",
                         "type": "choice", "options": ["auto", "github", "force-start-failure"]}}}):
        flag("workflow", "xcc-contract", "Router needs its exact main-only interface and account budget serialization")
    if path == XCC_DISPATCH_WORKFLOW and (document.get("name") != "ci-xcode-cloud-dispatch"
            or events != {"workflow_run": {"workflows": ["ci-ui", "ci-xcode-cloud-route"],
                                           "types": ["requested", "completed"]}}
            or document.get("permissions") != {} or document.get("env")):
        flag("workflow", "xcc-contract", "Cloud event bridge has a fixed source interface and no inherited credentials")
    # Live consumers intentionally execute test bundles; publisher-only trusted command rules do not apply.
    # Their environment and test-time credentials instead have this separate admission contract.
    allowed_secret_locations = {'workflow.jobs.live-unit.steps[' + str(index) + '].env.' + key
        for index, step in enumerate(jobs.get('live-unit', {}).get('steps', []))
        if step.get('id') == 'live' and step.get('env') == LIVE_BINDINGS for key in LIVE_BINDINGS}
    live_job_locations = []
    implicit_locations = implicit_expression_locations(jobs)
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        environment = job.get('environment')
        environment = environment.get('name') if isinstance(environment, dict) else environment
        if isinstance(environment, str) and environment.casefold() == LIVE_ENVIRONMENT:
            live_job_locations.append(f'workflow.jobs.{job_id}.')
    for location, value in string_scalars(document):
        if (path in XCC_WORKFLOWS and re.search(r"\bsecrets\b", value, re.IGNORECASE)
                or re.search(r"\bsecrets\s*(?:\.\s*ASC_|\[\s*['\"]ASC_)", value, re.IGNORECASE)):
            allowed_xcc = {"workflow.jobs." + job_id + ".steps[" + str(index) + "].env." + key
                           for job_id in ({"import"} if path == XCC_IMPORT_WORKFLOW else {"start", "route"} if path == XCC_ROUTE_WORKFLOW else set())
                           for index, step in enumerate(jobs.get(job_id, {}).get("steps", []))
                           if step.get("id") in ({"import"} if path == XCC_IMPORT_WORKFLOW else {"prepare", "start", "route"})
                           and step.get("env") == (XCC_CONTROL_BINDINGS if step.get("id") == "prepare" else XCC_BINDINGS)
                           for key in XCC_BINDINGS if key.startswith("ASC_")}
            if path not in XCC_WORKFLOWS or location not in allowed_xcc:
                flag(location, "xcc-credential", "ASC secrets belong only to the guarded main importer step")
        live_scope = (any(location.startswith(prefix) for prefix in live_job_locations)
                      or bool(live_job_locations) and location.startswith('workflow.env.'))
        if (live_scope and any(names_secrets_root(code) for code in expression_code(location, value, implicit_locations))
                or any(names_secrets_root(code, LIVE_SECRET_REFERENCE) for code in
                       expression_code(location, value, implicit_locations, keep_index_literals=True))):
            if path != LIVE_WORKFLOW or location not in allowed_secret_locations:
                flag(location, 'live-credential', 'Live secret references belong only to the guarded injection environment')
    for location, item in walk_mappings(document):
        name = item.get("environment")
        name = name.get("name") if isinstance(name, dict) else name
        if isinstance(name, str) and '${{' in name:
            flag(location, 'live-credential', 'Environment names must be literal to verify credential isolation')
        if isinstance(name, str) and name.casefold() in {LIVE_ENVIRONMENT, "test-server"}:
            refusal = (location == "workflow.jobs.live-environment-refusal" and
                       item.get("if") == "github.event_name == 'workflow_dispatch' && inputs.probe_environment_refusal && github.ref != 'refs/heads/main'" and
                       item.get("permissions") == {} and item.get("steps") == [{"run": "/usr/bin/false"}])
            consumer = (location == "workflow.jobs.live-unit" and item.get("needs") == ["live-admission", "live-build"] and
                        item.get("if") == "needs.live-admission.outputs.admitted == 'true'")
            if path != LIVE_WORKFLOW or name != LIVE_ENVIRONMENT or not (refusal or consumer):
                flag(location, "live-credential", "Live environment belongs only to guarded nightly units or the credential-free refusal probe")
        env = item.get("env", {})
        if isinstance(env, dict) and any("secrets.IMMICH_TEST_SERVER_" in str(value) or key in LIVE_BINDINGS for key, value in env.items()):
            consumer = jobs.get("live-unit", {})
            steps = consumer.get("steps", [])
            if (path != LIVE_WORKFLOW or env != LIVE_BINDINGS or item.get("id") != "live" or item not in steps
                    or consumer.get("environment") != LIVE_ENVIRONMENT
                    or consumer.get("if") != "needs.live-admission.outputs.admitted == 'true'"
                    or not any(step.get("run") == "/usr/bin/python3 -B scripts/ci_live_tests.py admit" for step in steps[:steps.index(item)])):
                flag(location, "live-credential", "Live secrets belong only to test-time injection after credential-free admission")
    trusted = path in TRUSTED_WORKFLOWS or bool({"pull_request_target", "workflow_run"} & set(events))
    if path in PUBLISHER_COMMANDS and isinstance(document.get("env"), dict):
        if any(isinstance(key, str) and key.startswith("CI_APP_") for key in document["env"]):
            flag("env", "publisher-credential", "App credentials cannot be inherited from workflow environment")
    for job_id, job in jobs.items():
        location = f"jobs.{job_id}"
        if not isinstance(job, dict):
            flag(location, "workflow-format", "Expected a job mapping")
            continue
        if path in PUBLISHER_COMMANDS and job.get("runs-on") != "ubuntu-24.04":
            flag(location, "publisher-runner", "Publisher and approval jobs use the pinned Linux runner")
        if path in PUBLISHER_COMMANDS and isinstance(job.get("env"), dict):
            if any(isinstance(key, str) and key.startswith("CI_APP_") for key in job["env"]):
                flag(location, "publisher-credential", "App credentials cannot be inherited from job environment")
        if approval_workflow and "concurrency" in job:
            flag(location, "approval-queue", "Approval jobs cannot enter a replaceable concurrency queue")
        permissions = job.get("permissions", document.get("permissions"))
        if not explicit_permissions(permissions):
            flag(location, "permissions", "Job needs explicit permissions, directly or inherited")
        if path == XCC_IMPORT_WORKFLOW:
            if (job_id != "import" or job.get("if") != "github.ref == 'refs/heads/main'"
                    or job.get("runs-on") != "ubuntu-24.04" or job.get("environment") != "xcode-cloud"
                    or job.get("timeout-minutes") != 10
                    or permissions != {"contents": "read", "actions": "read", "checks": "read", "pull-requests": "read"}
                    or job.get("env") or document.get("env")
                    or job.get("concurrency") != {"group": "ci-xcc-import-${{ inputs.producer_run_id }}-${{ inputs.producer_attempt }}", "cancel-in-progress": False}):
                flag(location, "xcc-contract", "Importer is bounded, main-only and credential-scoped with read-only grants")
        if path == XCC_ROUTE_WORKFLOW:
            start = job_id == "start"
            expected_if = "github.ref == 'refs/heads/main' && github.event_name == 'workflow_dispatch'" + ("" if start else " && needs.start.outputs.recorded == 'true'")
            group = "ci-xcc-account-budget" if start else "ci-xcc-poll-${{ inputs.producer_run_id }}-${{ inputs.producer_attempt }}"
            if (job_id not in {"start", "route"} or job.get("if") != expected_if
                    or job.get("runs-on") != "ubuntu-24.04" or job.get("environment") != "xcode-cloud"
                    or job.get("timeout-minutes") != (20 if start else 110) or job.get("env") or document.get("env")
                    or job.get("concurrency") != {"group": group, "cancel-in-progress": False}
                    or (not start and job.get("needs") != "start")
                    or permissions != {"contents": "read", "actions": "read", "checks": "read", "pull-requests": "read"}):
                flag(location, "xcc-contract", "Short global start lock and separate per-producer polling are main-only and bounded")
            phase_ids = [step.get("id") for step in job.get("steps", []) if isinstance(step, dict) and step.get("env")]
            if phase_ids != (["prepare", "start"] if start else ["route"]):
                flag(location, "xcc-credential", "Each router job executes only its reviewed credential phases")
            if start:
                steps = job.get("steps", [])
                reservation = [index for index, step in enumerate(steps) if isinstance(step, dict)
                               and step.get("with", {}).get("name") == "ci-xcc-reservation-${{ github.run_id }}-${{ github.run_attempt }}"]
                post = [index for index, step in enumerate(steps) if isinstance(step, dict) and step.get("id") == "start"]
                prepare = [index for index, step in enumerate(steps) if isinstance(step, dict) and step.get("id") == "prepare"]
                if not (len(prepare) == len(reservation) == len(post) == 1 and prepare[0] < reservation[0] < post[0]
                        and steps[post[0]].get("if") == "success() && steps.prepare.outputs.recorded == 'true'"
                        and job.get("outputs") == {"recorded": "${{ steps.start.outputs.recorded }}"}):
                    flag(location, "xcc-reservation", "Upload the immutable reservation successfully before any start")
        if (any(label in str(job.get("runs-on", "")) for label in ("macos-", "xcode-"))
                and any(re.search(r"\balways\s*\(", code, re.IGNORECASE) for code in expression_code("workflow." + location + ".if", str(job.get("if", "")), implicit_locations))):
            flag(location, "macos-cancellation", "macOS jobs must stop on cancellation; never use job-level always()")
        if path == XCC_DISPATCH_WORKFLOW and (job_id != "dispatch" or job.get("if") != XCC_DISPATCH_GUARD
                or job.get("runs-on") != "ubuntu-24.04" or job.get("timeout-minutes") != 5
                or "environment" in job or job.get("env")
                or permissions != {"contents": "read", "actions": "write", "pull-requests": "read"}):
            flag(location, "xcc-contract", "Cloud bridge is main-only, bounded, environment-free and grants only dispatch authority")
        if path == PROBE_WORKFLOW and permissions != {"contents": "read", "issues": "write"}:
            flag(location, "probe-contract", "ci-probe grants only contents: read and issues: write at job level")
        if path == REPORT_WORKFLOW:
            if (permissions != {"contents": "read", "actions": "read", "pull-requests": "read", "issues": "write"}
                    or job.get("runs-on") != "ubuntu-24.04" or "environment" in job
                    or job.get("if") != "github.ref == 'refs/heads/main' && "
                    "(github.event_name != 'workflow_run' || "
                    "(github.event.workflow_run.head_repository.full_name == github.repository && github.event.workflow_run.head_branch == 'main' && "
                    "((github.event.workflow_run.name == 'ci-nightly' && contains(fromJSON('[\"schedule\",\"workflow_dispatch\"]'), github.event.workflow_run.event)) || "
                    "(contains(fromJSON('[\"ci-gate\",\"ci-ui\"]'), github.event.workflow_run.name) && github.event.workflow_run.event == 'push'))))"
                    or job.get("concurrency") != {"group": "ci-report-state", "cancel-in-progress": False}):
                flag(location, "report-contract", "Reporter is serialized, main-only, excludes branch nightly, is environment-free and has only issue write")
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
            if path == REPORT_WORKFLOW:
                collect = [i for i, step in enumerate(steps) if isinstance(step, dict)
                           and step.get("run", "").endswith("scripts/ci_report.py --phase collect")]
                sync = [i for i, step in enumerate(steps) if isinstance(step, dict)
                        and step.get("run", "").endswith("scripts/ci_report.py --phase sync")]
                daily = [i for i, step in enumerate(steps) if isinstance(step, dict)
                         and step.get("uses", "").startswith("actions/upload-artifact@")
                         and step.get("with", {}).get("path") == "${{ runner.temp }}/ci-report/daily"]
                health = [i for i, step in enumerate(steps) if isinstance(step, dict)
                          and step.get("uses", "").startswith("actions/upload-artifact@")
                          and step.get("with", {}).get("path") == "${{ runner.temp }}/ci-report/health"]
                if not (len(collect) == len(sync) == len(daily) == 1 and collect[0] < daily[0] < sync[0]
                        and steps[daily[0]].get("if") == "success()" and steps[sync[0]].get("if") == "success()"):
                    flag(location, "report-contract", "Upload the verified daily rollup before issue synchronization")
                if not (len(daily) == len(health) == len(sync) == 1 and daily[0] < health[0] < sync[0]
                        and steps[health[0]].get("if") == "success() && steps.collect.outputs.health_month != ''"):
                    flag(location, "report-contract", "Upload requested monthly health after daily history and before issue synchronization")
            if path in PUBLISHER_COMMANDS and any(step.get("run", "").endswith("scripts/ci_publish.py publish")
                                                 for step in steps if isinstance(step, dict)):
                checkouts = [step for step in steps if isinstance(step, dict)
                             and step.get("uses", "").startswith("actions/checkout@")]
                if len(checkouts) != 1 or checkouts[0].get("with", {}).get("fetch-depth") != 0:
                    flag(location, "publisher-history", "Publication needs full history for admitted historical readers")
            for index, step in enumerate(steps):
                if not isinstance(step, dict):
                    continue
                step_location = f"{location}.steps[{index}]"
                if path == XCC_DISPATCH_WORKFLOW and "env" in step:
                    if (step.get("env") != {"CI_WORKFLOW_TOKEN": "${{ github.token }}"} or step.get("id") != "dispatch"
                            or step.get("run") != '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_xcode_cloud_dispatch.py'):
                        flag(step_location, "xcc-credential", "Cloud bridge has only its GitHub dispatch token")
                if path in XCC_WORKFLOWS and "env" in step:
                    role = "import" if path == XCC_IMPORT_WORKFLOW else step.get("id")
                    phase = {"prepare": "prepare", "start": "start", "route": "poll"}.get(role)
                    command = ('"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_xcode_cloud_import.py' if role == "import" else
                               '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_xcode_cloud_route.py ' + str(phase))
                    if (step.get("env") != (XCC_CONTROL_BINDINGS if role == "prepare" else XCC_BINDINGS)
                            or role not in ({"import"} if path == XCC_IMPORT_WORKFLOW else {"prepare", "start", "route"})
                            or step.get("run") != command):
                        flag(step_location, "xcc-credential", "ASC credentials belong only to the importer entry point")
                if (path in PUBLISHER_COMMANDS and step.get("run", "").endswith("scripts/ci_publish.py reevaluate")
                        and step.get("if") != "steps.admit.outputs.recorded == 'true'"):
                    flag(step_location, "publisher-admission", "Admission re-evaluates only after recording a new admission")
                if "run" in step and not trusted_run_allowed(step["run"], path, events):
                    flag(step_location, "trusted-run", "Trusted run must be an allowlisted literal command or entry point")
                settings = {key: step[key] for key in ("shell", "working-directory") if key in step}
                if not trusted_run_settings_allowed(settings):
                    flag(step_location, "trusted-run", "Trusted commands require the default workspace and a reviewed shell")
                if path in PUBLISHER_COMMANDS and isinstance(step.get("env"), dict):
                    if {"CI_APP_PRIVATE_KEY", "CI_APP_ID"}.intersection(step["env"]):
                        environment = job.get("environment")
                        environment_name = environment.get("name") if isinstance(environment, dict) else environment
                        command = step.get("run", "")
                        allowed_command = ("publish" if path.endswith("ci-publish.yml") else "approve"
                                           if path.endswith("ci-approval.yml") else "fallback")
                        if (environment_name != "ci-publisher" or command !=
                                '"$RUNNER_TEMP/ci-python/bin/python3" -B scripts/ci_publish.py ' + allowed_command):
                            flag(step_location, "publisher-credential", "App credentials belong only to the guarded status-writing step")
        if path == ".github/workflows/ci-approval.yml" and job.get("environment") == "ci-approval":
            if (permissions != {} or job.get("env") or document.get("env")
                    or steps != [{"run": "/usr/bin/true"}]):
                flag(location, "approval-wait", "Approval wait must have no credentials, checkout, actions or token grants")
        if trusted and any(key in job for key in ("container", "services")):
            flag(location, "trusted-run", "Trusted jobs cannot start unreviewed containers or services")
    for location, item in walk_mappings(document):
        permissions = item.get("permissions")
        if isinstance(permissions, dict) and permissions.get("issues") == "write" and path not in ISSUE_WRITE_WORKFLOWS:
            flag(location, "issue-write", "Issue writes are reserved for ci-probe and ci-report")
        if "uses" in item and not pinned_action(item["uses"]):
            flag(location, "action-pin", "Remote uses must have a full commit SHA; container actions need a sha256 digest")
        if not trusted:
            continue
        environment = item.get("env", {})
        loader_variables = {"PATH", "BASH_ENV", "ENV", "PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS",
                            "RUBYLIB", "PERL5LIB", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES"}
        if isinstance(environment, dict) and any(key in loader_variables for key in environment):
            flag(location, "artifact-execution", "Artifact data must not control executable search or interpreter startup")
        bindings = (PRIVACY_ENVIRONMENT if path == PRIVACY_WORKFLOW else PROBE_ENVIRONMENT
                    if path == PROBE_WORKFLOW else {"CI_WORKFLOW_TOKEN": "${{ github.token }}"} if path == XCC_DISPATCH_WORKFLOW
                    else XCC_CONTROL_BINDINGS if path == XCC_ROUTE_WORKFLOW else XCC_BINDINGS if path in XCC_WORKFLOWS
                    else {"CI_REPORT_TOKEN": "${{ github.token }}"} if path == REPORT_WORKFLOW
                    else PUBLISHER_BINDINGS if path in PUBLISHER_COMMANDS else {})
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
        publisher_upload = (path == ".github/workflows/ci-publish.yml"
                            and uses == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
                            and options in ({"name": "ci-admission-${{ steps.admit.outputs.run_id }}",
                                             "path": "${{ runner.temp }}/ci-admission/record.json",
                                             "if-no-files-found": "error", "retention-days": 30},
                                            {"name": "ci-ui-verdict-${{ steps.publish.outputs.ui_verdict_tree }}",
                                             "path": "${{ runner.temp }}/ci-ui-verdict/verdict.json",
                                             "if-no-files-found": "error", "retention-days": 30}))
        role = "import" if path == XCC_IMPORT_WORKFLOW else "route"
        xcc_upload = (path in XCC_WORKFLOWS and uses == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
                      and options == {"name": "ci-xcc-" + role + "-${{ steps." + role + ".outputs.producer_run_id }}-${{ steps." + role + ".outputs.producer_attempt }}",
                                      "path": "${{ runner.temp }}/ci-xcc-" + role + ("/cloud.json" if role == "import" else "/route.json"),
                                      "if-no-files-found": "error", "retention-days": 30}
                      and item.get("if") == ("success() && steps.import.outputs.imported == 'true'" if role == "import"
                                             else "success() && steps.route.outputs.recorded == 'true'"))
        if path == XCC_ROUTE_WORKFLOW and uses == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02":
            xcc_upload |= any(options == {"name": "ci-xcc-" + stage + "-${{ github.run_id }}-${{ github.run_attempt }}",
                                          "path": "${{ runner.temp }}/ci-xcc-route/" + member + ".json",
                                          "if-no-files-found": "error", "retention-days": 90}
                              and item.get("if") == guard for stage, member, guard in (
                                  ("reservation", "reservation", "success() && steps.prepare.outputs.reserved == 'true'"),
                                  ("start", "start", "success() && steps.start.outputs.recorded == 'true'")))
        report_upload = (path == REPORT_WORKFLOW and uses == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
                         and any(options == {"name": f"ci-report-{name}-${{{{ github.run_id }}}}-${{{{ github.run_attempt }}}}",
                                             "path": "${{ runner.temp }}/ci-report/" + directory,
                                             "if-no-files-found": missing, "retention-days": retention}
                                 for name, directory, missing, retention in (("daily", "daily", "error", 90),
                                     ("runs", "runs", "ignore", 7))) or
                         path == REPORT_WORKFLOW and uses == "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
                         and options == {"name": "ci-report-health-${{ steps.collect.outputs.health_month }}-${{ github.run_id }}-${{ github.run_attempt }}",
                                         "path": "${{ runner.temp }}/ci-report/health", "if-no-files-found": "error", "retention-days": 90})
        if "uses" in item and not publisher_upload and not report_upload and not xcc_upload and not trusted_action_allowed(uses, options):
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
            if path == REPORT_WORKFLOW and (ref != "main" or options.get("fetch-depth") != 0):
                flag(location, "report-contract", "Reporter needs explicit main checkout and full history")
            if path in XCC_WORKFLOWS | {XCC_DISPATCH_WORKFLOW} and (ref != "main" or options.get("fetch-depth") != 0
                                                or options.get("persist-credentials") is not False):
                flag(location, "xcc-contract", "Importer needs main, full history and no persisted checkout credential")
        if isinstance(uses, str) and "download-artifact" in uses.lower() and not artifact_path(options.get("path")):
            flag(location, "artifact-execution", "Download artifact data only into an explicit ci-artifacts directory")
        if "script" in options:
            flag(location, "artifact-execution", "Trusted actions cannot execute inline scripts")
    return violations


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="Repository root (default: this script's repository)")
    parser.add_argument("--check-ui-shards", action="store_true",
                        help="Also validate the checked-in UI shard assignments against both platforms")
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
    if args.check_ui_shards:
        from ci_population import ui_identities
        from ci_ui_shards import MANIFEST_PATH, validate_shard_assignments
        try:
            sources = {path.relative_to(args.root).as_posix(): path.read_text(encoding="utf-8")
                       for path in (args.root / "immichSlidesUITests").rglob("*.swift")}
            populations = {"ui-" + platform: ui_identities(sources, platform) for platform in ("ios", "tvos")}
            validate_shard_assignments((args.root / MANIFEST_PATH).read_text(encoding="utf-8"), populations)
        except (OSError, UnicodeError, ValueError) as error:
            violations.append(Violation(MANIFEST_PATH, "manifest", "ui-shards", str(error)))
    for violation in violations:
        print(violation, file=sys.stderr)
    print(f"Workflow policy {'FAIL' if violations else 'PASS'}: {len(paths)} workflows, {len(violations)} violations")
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
