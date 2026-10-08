"""Git-object input and an isolated base-revision verdict reader.

Candidate trees are text only. Only the admitted first parent's allowlisted
reader modules are ever materialized as executable Python.
"""

from __future__ import annotations

import ast
import itertools
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

from ci_summary import require, sha, test_identity

BASE_MODULES = ("ci_summary.py", "ci_population.py", "ci_verdict.py", "ui_test_inventory.py",
                "run_host_checks.py")
OPTIONAL_BASE_MODULES = ("ci_flaky.py",)
BRIDGE = '''import json,sys
sys.path.insert(0, sys.argv[1])
from ci_population import python_identities,swift_identities,ui_identities
from ci_summary import test_identity
from ci_verdict import classify_changes,evaluate_gate
from run_host_checks import HOST_CHECKS
p=json.load(sys.stdin)
if p['operation']=='derive':
    sources=p['sources']
    py={path[8:-3].replace('/', '.'):text for path,text in sources.items() if path.startswith('scripts/') and path.endswith('.py')}
    swift={path:text for path,text in sources.items() if path.startswith('immichSlidesTests/') and path.endswith('.swift')}
    ui={path:text for path,text in sources.items() if path.startswith('immichSlidesUITests/') and path.endswith('.swift')}
    population={'host':[test_identity('host',name) for name,_ in HOST_CHECKS]+python_identities(py)}
    for platform in ('ios','tvos'):
        population['unit-'+platform]=swift_identities(swift,platform)
        population['ui-'+platform]=ui_identities(ui,platform)
    classification=classify_changes(p['paths'],p['classification_policy'],build_target_paths=p['build_target_paths'])
    result={'populations':population,'classification':classification}
else:
    result=evaluate_gate(p['summaries'],**p['inputs'])
print(json.dumps(result))
'''


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


def trusted_reader(record):
    revision = record["reader_revision"]
    identity = record["identity"]
    require(revision == identity.get("base_sha", identity.get("pushed_sha")), "reader differs from admitted base")
    sha(revision)
    git("fetch", "--no-tags", "origin", "refs/heads/main")
    require(subprocess.run(["git", "merge-base", "--is-ancestor", revision, "FETCH_HEAD"],
                           capture_output=True, timeout=30).returncode == 0, "historical reader is not on main")
    # Read modules from verified Git history, never from an artifact. Main's
    # history retains this base even after the ephemeral PR merge ref expires.
    return revision_modules(revision)


def derive_record(identity, run, *, before=None):
    commit = identity.get("merge_sha", identity.get("pushed_sha"))
    base = identity.get("base_sha", commit)
    modules = revision_modules(base)
    listing, sources = tree_inputs(commit)
    if identity["event"] == "pull_request":
        paths = git("diff", "--name-only", "--no-renames", base + "..." + identity["head_sha"]).splitlines()
    else:
        # workflow_run omits the push's before SHA. Without an independently
        # verified range, a burst is unknown and must run the UI tier.
        paths = git("diff", "--name-only", "--no-renames", before, commit).splitlines() if before else ["__unknown_push_range__"]
    paths = paths or ["__unknown_empty_diff__"]
    payload = {"operation": "derive", "sources": sources, "paths": paths,
               "classification_policy": json.loads(read_blob(base, "scripts/ci-classification.json")),
               "build_target_paths": [entry["path"] for entry in listing if entry["path"].startswith("immichSlides/")]}
    derived = base_reader(modules, payload)
    base_listing, base_sources = tree_inputs(base)
    payload["sources"] = base_sources
    base_derived = base_reader(modules, payload)
    workflows = {}
    for path in (".github/workflows/ci-gate.yml", ".github/workflows/ci-ui.yml"):
        if any(entry["path"] == path for entry in base_listing):
            workflows[path] = {"base": read_blob(base, path), "candidate": read_blob(commit, path)}
    operational = {}
    syntax = ast.parse(read_blob(base, "scripts/ci_build_archive.py"))
    for function in syntax.body:
        if isinstance(function, ast.FunctionDef) and function.name in {"run_build", "run_proof"}:
            calls = [node for node in ast.walk(function) if isinstance(node, ast.Call)
                     and isinstance(node.func, ast.Name) and node.func.id == "test_identity"]
            require(len(calls) == 1 and len(calls[0].args) == 2
                    and all(isinstance(arg, ast.Constant) for arg in calls[0].args), "unsupported operational inventory")
            call = calls[0]
            configuration = next(keyword.value.value for keyword in call.keywords if keyword.arg == "configuration"
                                 and isinstance(keyword.value, ast.Constant))
            operational[function.name] = {platform: [test_identity(call.args[0].value, call.args[1].value,
                                         platform=platform, configuration=configuration)] for platform in ("ios", "tvos")}
    return {"schema_version": 1, "run_id": run["id"], "workflow_id": run["workflow_id"],
            "workflow_path": run["path"], "identity": identity, "tree_listing": listing,
            "populations": derived["populations"], "base_populations": base_derived["populations"],
            "operational_populations": operational,
            "classification": derived["classification"], "reader_revision": base, "workflows": workflows,
            "base_policy": json.loads(read_blob(base, "scripts/ci-test-policy.json")),
            "candidate_policy": json.loads(read_blob(commit, "scripts/ci-test-policy.json"))}


def render_expression(value, bindings):
    require(isinstance(value, str), "workflow name must be a string")
    for key, replacement in bindings.items():
        value = re.sub(r"\$\{\{\s*" + re.escape(key) + r"\s*\}\}", str(replacement), value)
    require("${{" not in value, "unsupported dynamic producer name")
    return value


def producer_commands(source):
    # Copying a script into relocated tooling does not execute its producer.
    commands = []
    for line in source.replace("\\\n", " ").splitlines():
        words = shlex.split(line, comments=True)
        if not words or not (words[0] in {"$PYTHON", "${PYTHON}"} or Path(words[0]).name == "python3"):
            continue
        arguments = words[1:]
        while arguments and arguments[0] in {"-B", "-I"}:
            arguments = arguments[1:]
        if arguments:
            commands.append((Path(arguments[0]).name, arguments[1:]))
    return commands


def workflow_contract(source, run, *, details=False, metadata=False):
    # The workflow is data from the admitted trusted base (or exact-head approved
    # metadata), never an executable candidate workflow in this process.
    from check_workflow_policy import WorkflowLoader
    workflow = yaml.load(source, Loader=WorkflowLoader)
    jobs, artifacts, artifacts_by_job, evidence = [], [], {}, {}
    for key, job in workflow["jobs"].items():
        matrix = job.get("strategy", {}).get("matrix", {})
        require(not {"include", "exclude"}.intersection(matrix), "matrix inclusion requires a supported reader")
        require(all(isinstance(values, list) for values in matrix.values()), "dynamic matrix is unsupported")
        combinations = itertools.product(*matrix.values()) if matrix else [()]
        for values in combinations:
            bindings = {"github.run_id": run["id"], "github.run_attempt": run["run_attempt"]}
            bindings.update({"matrix." + name: value for name, value in zip(matrix, values)})
            bindings.update({"env." + name: value for name, value in job.get("env", {}).items()
                             if isinstance(value, str) and "${{" not in value})
            job_name = render_expression(job.get("name", key), bindings)
            jobs.append(job_name)
            artifacts_by_job[job_name] = []
            scripts = "\n".join(step.get("run", "") for step in job.get("steps", []))
            for binding, replacement in bindings.items():
                scripts = re.sub(r"\$\{\{\s*" + re.escape(binding) + r"\s*\}\}", str(replacement), scripts)
            commands = producer_commands(scripts)
            producers = []
            if any(script == "run_host_checks.py" for script, _ in commands):
                producers.append({"tier": "host", "job": "host-checks", "shard": None, "population": "host"})
            operations = {arguments[0] for script, arguments in commands
                          if script == "ci_build_archive.py" and arguments and arguments[0] in {"build", "proof"}}
            unit = any(script == "ci_unit_tests.py" and arguments and arguments[0] == "run"
                       for script, arguments in commands)
            if operations or unit:
                platforms = {arguments[index + 1] for script, arguments in commands
                             if script in {"ci_build_archive.py", "ci_unit_tests.py"}
                             for index, argument in enumerate(arguments[:-1])
                             if argument == "--platform" and arguments[index + 1] in {"ios", "tvos"}}
                require(len(platforms) == 1, "producer platform must be independently known from workflow metadata")
                platform = platforms.pop()
                for operation in set(operations):
                    producers.append({"tier": "build", "job": "build-" + platform if operation == "build" else "archive-relocation",
                                      "shard": platform, "population": "run_build" if operation == "build" else "run_proof"})
                if unit:
                    producers.append({"tier": "unit", "job": "unit-" + platform, "shard": platform,
                                      "population": "unit-" + platform})
            require(len(producers) <= 1, "a workflow job needs one supported evidence producer")
            for step in job.get("steps", []):
                if step.get("uses", "").startswith("actions/upload-artifact@"):
                    options = step["with"]
                    if "summary.json" in options.get("path", "") or options.get("path", "").endswith("/records"):
                        name = render_expression(options["name"], bindings)
                        artifacts.append(name)
                        artifacts_by_job[job_name].append(name)
            if metadata:
                require(len(producers) == len(artifacts_by_job[job_name]) == 1,
                        "each required job needs a supported producer and one bound summary artifact")
                evidence[job_name] = producers[0]
    require(len(jobs) == len(set(jobs)) and len(artifacts) == len(set(artifacts)), "duplicate workflow job or record name")
    if metadata:
        return jobs, artifacts, artifacts_by_job, evidence
    return (jobs, artifacts, artifacts_by_job) if details else (jobs, artifacts)


def evaluate_records(record, run, jobs, summaries, *, approved, fork):
    source = record["workflows"][run["path"]]["candidate" if approved else "base"]
    expected_jobs, _, _, metadata = workflow_contract(source, run, metadata=True)
    actual = {job["name"]: job for job in jobs}
    require(set(actual) == set(expected_jobs) and len(jobs) == len(actual), "required workflow jobs differ")
    require(all(job["status"] == "completed" and job["conclusion"] == "success" for job in jobs),
            "a required job failed, skipped or was cancelled")
    context = "gate" if run["path"].endswith("ci-gate.yml") else "ui"
    tree = record["identity"]["tree_sha"]
    def population(meta):
        return (record["operational_populations"][meta["population"]][meta["shard"]]
                if meta["tier"] == "build" else record["populations"][meta["population"]])
    required_jobs = [{"tier": meta["tier"], "job": meta["job"], "shard": meta["shard"],
                      "run_id": str(run["id"]), "attempt": actual[name]["evidence_attempt"],
                      "workflow_paths": [run["path"]], "expected": {"tree_sha": tree, "identities": population(meta)},
                      "status": actual[name]["status"], "conclusion": actual[name]["conclusion"]}
                     for name, meta in metadata.items()]
    parts = ["host", "unit-ios", "unit-tvos"] if context == "gate" else ["ui-ios", "ui-tvos"]
    expected = [identity for part in parts for identity in record["populations"][part]]
    base_expected = [identity for part in parts for identity in record["base_populations"][part]]
    if context == "gate":
        required_operations = {"run_build"} | {meta["population"] for meta in metadata.values() if meta["tier"] == "build"}
        operations = [identity for operation, platforms in record["operational_populations"].items() if operation in required_operations
                      for identities in platforms.values() for identity in identities]
        expected += operations
        base_expected += operations
    inputs = {"expected": {"tree_sha": tree, "identities": expected}, "admission_identity": record["identity"],
              "required_jobs": required_jobs, "base_policy": record["base_policy"], "candidate_policy": record["candidate_policy"],
              "environment": "hermetic", "approved_head": record["identity"].get("head_sha") if approved else None,
              "fork_originated": fork, "ci_changing": record["classification"]["ci_changing"],
              "app_affected": record["classification"]["app_affected"], "context": context,
              "base_population": {"base_sha": record["identity"].get("base_sha"), "identities": base_expected}}
    modules = trusted_reader(record)
    verdict = base_reader(modules, {"operation": "gate", "summaries": summaries, "inputs": inputs})
    missing_units = context == "gate" and {meta["population"] for meta in metadata.values() if meta["tier"] == "unit"} != {"unit-ios", "unit-tvos"}
    if missing_units and verdict["errors"] == ["invalid evidence: required-job population differs from tested tree"]:
        # Validate the existing producer evidence with the same base evaluator;
        # this partial pipeline can be pending, but can never establish success.
        partial = dict(inputs, expected={"tree_sha": tree, "identities": [identity for job in required_jobs for identity in job["expected"]["identities"]]})
        observed = base_reader(modules, {"operation": "gate", "summaries": summaries, "inputs": partial})
        if observed["status"] == "passed":
            return {"state": "pending", "description": "unit tier not yet produced"}
    details = [{"tier": summary["run"]["tier"], "shard": summary["run"]["shard"],
                "expected": len(job["expected"]["identities"]), "compiled": len(summary["population"]["compiled"]),
                "observed": len(summary["population"]["observed"])} for job in required_jobs for summary in summaries
               if all(job[key] == summary["run"][key] for key in ("tier", "job", "shard"))]
    return {"state": "success" if verdict["status"] in {"passed", "not-applicable"} else "failure",
            "description": "All required jobs and admitted populations passed" if verdict["status"] == "passed" else
                           "Not applicable: trusted classification cannot affect the app" if verdict["status"] == "not-applicable" else "Base gate refused incomplete or invalid evidence",
            "source": {"repository": record["identity"]["repository"], "workflow_path": run["path"],
                       "run_id": run["id"], "attempt": run["run_attempt"], "approval_based": verdict["approval_based"], "fork_originated": fork},
            "population": details, "expected_skips": verdict["expected_skips"], "deselected": verdict["deselected"],
            "removed_by_pr": verdict["removed_by_pr"]}
