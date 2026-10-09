"""Git-object input and an isolated base-revision verdict reader.

Candidate trees are text only. Only the admitted first parent's allowlisted
reader modules are ever materialized as executable Python.
"""

from __future__ import annotations

import ast
import hashlib
import itertools
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

import yaml

from ci_summary import ContractError, decode, require, sha, test_identity
from ci_ui_shards import DEVICES, MANIFEST_PATH, default_plan_population, parse_shard_manifest, shard_populations

BASE_MODULES = ("ci_summary.py", "ci_population.py", "ci_verdict.py", "ui_test_inventory.py",
                "run_host_checks.py")
OPTIONAL_BASE_MODULES = ("ci_flaky.py", "ci_ui_shards.py")
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
elif p['operation']=='classify':
    result=classify_changes(p['paths'],p['classification_policy'],build_target_paths=p['build_target_paths'])
elif p['operation']=='ui':
    import ci_ui_shards
    from ci_ui_shards import DEVICES,default_plan_population,shard_populations
    result={'populations':{},'base_populations':{}}
    for device in p['devices']:
        platform=DEVICES[device]
        plan=p['plans'][platform]['plan']
        result['base_populations'][device]=[test_identity('ui',entry['key'],platform=platform,device=device)
            for entry in default_plan_population(p['base_populations']['ui-'+platform],plan)]
    try:
        if hasattr(ci_ui_shards,'validate_shard_assignments'):
            ci_ui_shards.validate_shard_assignments(p['manifest'],p['populations'])
        for device in p['shard_devices']:
            platform=DEVICES[device]
            result['populations'][device]=shard_populations(p['populations']['ui-'+platform],p['plans'][platform]['plan'],p['manifest'],device)
    except Exception as error:
        result['error']=str(error)
else:
    if 'evaluated_on' in p['inputs']:
        from datetime import date
        p['inputs']['evaluated_on']=date.fromisoformat(p['inputs']['evaluated_on'])
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
        empty_shard = re.search(r"^ci_summary.ContractError: (shard [a-z][a-z0-9-]* has no tests on "
                               r"(?:iphone|ipad|appletv); update scripts/ci-ui-shards\.json)$", result.stderr, re.MULTILINE)
        require(result.returncode == 0, empty_shard.group(1) if empty_shard else "base reader refused static inputs")
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
        present_base = any(entry["path"] == path for entry in base_listing)
        present_candidate = any(entry["path"] == path for entry in listing)
        if present_base or present_candidate:
            workflows[path] = {"base": read_blob(base, path) if present_base else None,
                               "candidate": read_blob(commit, path) if present_candidate else None}
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
    ui = {}
    for side, revision, entries in (("base", base, base_listing), ("candidate", commit, listing)):
        try:
            ui[side] = ui_inputs(revision, entries, populations=derived["populations"],
                                 base_populations=base_derived["populations"],
                                 workflow=workflows.get(".github/workflows/ci-ui.yml", {}).get(side), run=run, modules=modules)
        except Exception as error:
            if side == "base":
                raise
            # Bad candidate UI data cannot suppress a separate gate admission.
            ui[side] = {"error": ui_failure_hint(error) or "candidate UI inputs are invalid"}
    cloud_inputs = None
    from ci_xcode_cloud import PLAN_PATH, SCHEME_PATH
    cloud_paths = {PLAN_PATH, SCHEME_PATH, "scripts/strict_e2e_server.py", "ci_scripts/fixture_server.py"}
    candidate_paths = {entry["path"] for entry in listing if entry["type"] == "blob" and entry["mode"] in {"100644", "100755"}}
    if identity["event"] == "pull_request" and cloud_paths <= candidate_paths:
        head = identity["head_sha"]
        head_listing, _ = tree_inputs(head)
        head_paths = {entry["path"] for entry in head_listing
                      if entry["type"] == "blob" and entry["mode"] in {"100644", "100755"}}
        if cloud_paths <= head_paths:
            raw_plan = read_blob(head, "XcodeCloud-UI-tvOS.xctestplan")
            try:
                parsed_plan = decode(raw_plan)
            except (ContractError, TypeError, ValueError):
                parsed_plan = None
            cloud_inputs = {"plan": parsed_plan, "plan_sha256": hashlib.sha256(raw_plan.encode()).hexdigest(),
                            "scheme": read_blob(head, SCHEME_PATH),
                            "plan_paths": [entry["path"] for entry in head_listing
                                           if Path(entry["path"]).name.casefold() == PLAN_PATH.casefold()],
                            "head_tree_sha": git("rev-parse", head + "^{tree}"),
                            "fixture_sha256": hashlib.sha256(read_blob(head, "ci_scripts/fixture_server.py").encode()).hexdigest(),
                            "source_sha256": hashlib.sha256(read_blob(head, "scripts/strict_e2e_server.py").encode()).hexdigest()}
    return {"schema_version": 1, "run_id": run["id"], "workflow_id": run["workflow_id"],
            "workflow_path": run["path"], "identity": identity, "tree_listing": listing,
            "populations": derived["populations"], "base_populations": base_derived["populations"],
            "operational_populations": operational,
            "ui_inputs": ui,
            "cloud_inputs": cloud_inputs,
            "classification": derived["classification"], "reader_revision": base, "workflows": workflows,
            "base_registry": json.loads(read_blob(base, "scripts/ci-known-flaky.json"))
                             if any(entry["path"] == "scripts/ci-known-flaky.json" for entry in base_listing) else None,
            "base_policy": json.loads(read_blob(base, "scripts/ci-test-policy.json")),
            "candidate_policy": json.loads(read_blob(commit, "scripts/ci-test-policy.json"))}


def ui_failure_hint(error):
    message = str(error)
    if message == "workflow is absent on the base; exact-head approval required":
        return message
    if re.fullmatch(r"shard [a-z][a-z0-9-]* has no tests on (?:iphone|ipad|appletv); "
                    r"update scripts/ci-ui-shards\.json", message):
        return message
    return None


def ui_inputs(revision, listing, *, populations=None, base_populations=None, workflow=None, run=None, modules=None):
    paths = {entry["path"] for entry in listing if entry["type"] == "blob" and entry["mode"] in {"100644", "100755"}}
    if MANIFEST_PATH not in paths:
        return None
    raw = read_blob(revision, MANIFEST_PATH)
    result = {"manifest": parse_shard_manifest(raw), "manifest_sha256": hashlib.sha256(raw.encode()).hexdigest(), "plans": {}}
    for platform, suffix in (("ios", "iOS"), ("tvos", "tvOS")):
        path = "immichSlides-" + suffix + ".xctestplan"
        if path in paths:
            raw_plan = read_blob(revision, path)
            default_plan_population([], raw_plan)
            result["plans"][platform] = {"plan": decode(raw_plan), "sha256": hashlib.sha256(raw_plan.encode()).hexdigest()}
    result.update(populations={}, base_populations={})
    devices = []
    if workflow is not None:
        _, _, _, metadata = workflow_contract(workflow, run, metadata=True)
        devices = sorted({meta["device"] for meta in metadata.values() if meta["tier"] == "ui"})
        require(all(DEVICES[device] in result["plans"] for device in devices), "UI workflow device has no default plan")
    if modules is not None:
        computed = base_reader(modules, {"operation": "ui", "shard_devices": devices,
                      "devices": sorted(device for device, platform in DEVICES.items() if platform in result["plans"]), "populations": populations,
                      "base_populations": base_populations, "plans": result["plans"], "manifest": result["manifest"]})
        if "error" in computed:
            # Keep the base's own filtered population for an approved replacement
            # manifest; only the tested-tree shard computation failed.
            return {"error": ui_failure_hint(computed["error"]) or "UI shard populations are invalid",
                    "base_populations": computed["base_populations"]}
        result.update(computed)
    return result


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
    require(isinstance(source, str), "workflow is absent on the base; exact-head approval required")
    workflow = yaml.load(source, Loader=WorkflowLoader)
    require(isinstance(workflow, dict) and isinstance(workflow.get("jobs"), dict), "workflow needs literal jobs")
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
            if any(script == "ci_gate.py" and arguments and arguments[0] == "classify"
                   for script, arguments in commands):
                producers.append({"tier": "gate-infrastructure", "job": "gate-classification", "shard": None,
                                  "population": "gate-classification"})
            ui_operations = [(arguments[0], arguments) for script, arguments in commands
                             if script == "ci_ui_tests.py" and arguments and arguments[0] in {"wait-archive", "run"}]
            for operation, arguments in ui_operations:
                if operation == "wait-archive":
                    producers.append({"tier": "ui-infrastructure", "job": "ui-archive", "shard": None, "population": "ui-archive"})
                else:
                    def option(name):
                        indexes = [index for index, item in enumerate(arguments) if item == name]
                        require(len(indexes) == 1 and indexes[0] + 1 < len(arguments), "literal UI device/shard required")
                        return arguments[indexes[0] + 1]
                    device, shard = option("--device"), option("--shard")
                    require(device in DEVICES and re.fullmatch(r"[a-z][a-z0-9-]*", shard), "unknown UI device/shard")
                    producers.append({"tier": "ui", "job": "ui-" + device, "shard": shard,
                                      "population": "ui-" + DEVICES[device], "device": device})
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


def gate_not_applicable_jobs(record, run, metadata):
    # Only independent admission can excuse the four app build/unit jobs.
    classification = record["classification"] if record is not None else {}
    unaffected = (run["path"] == ".github/workflows/ci-gate.yml" and run["event"] == "pull_request"
                  and record is not None and record["identity"]["event"] == "pull_request"
                  and classification.get("app_affected") is False and classification.get("ci_changing") is False)
    return {name for name, meta in metadata.items() if unaffected
            and meta["tier"] in {"build", "unit"} and meta["shard"] in {"ios", "tvos"}
            and meta["job"] == meta["tier"] + "-" + meta["shard"]}


def evaluate_records(record, run, jobs, summaries, *, approved, fork, cloud=None):
    context = "gate" if run["path"].endswith("ci-gate.yml") else "ui"
    ui = record.get("ui_inputs", {}).get("candidate" if approved else "base") if context == "ui" else None
    if ui is not None:
        require("error" not in ui, ui.get("error", "candidate UI inputs are invalid"))
    source = record["workflows"][run["path"]]["candidate" if approved else "base"]
    expected_jobs, _, _, metadata = workflow_contract(source, run, metadata=True)
    actual = {job["name"]: job for job in jobs}
    require(set(actual) == set(expected_jobs) and len(jobs) == len(actual), "required workflow jobs differ")
    allowed_skips = gate_not_applicable_jobs(record, run, metadata)
    cloud_jobs = set()
    if cloud is not None:
        from ci_xcode_cloud import admitted_population
        require(context == "ui" and not fork and record["identity"]["event"] == "pull_request",
                "external Apple TV evidence cannot cover this source")
        require(cloud["identities"] == admitted_population(record, approved=approved), "external Apple TV population differs")
        cloud_jobs = {name for name, meta in metadata.items() if meta.get("device") == "appletv"}
        require(cloud_jobs and all(actual[name]["status"] == "completed" and actual[name]["conclusion"] == "skipped"
                and (actual[name].get("runner_id") is None or type(actual[name].get("runner_id")) is int
                     and actual[name]["runner_id"] == 0) and actual[name].get("steps") == [] for name in cloud_jobs),
                "routed GitHub Apple TV shards must be unexecuted literal skips")
        require(not any(summary["run"]["job"] == "ui-appletv" for summary in summaries),
                "mixed GitHub and Xcode Cloud Apple TV evidence")
        allowed_skips |= cloud_jobs
    require(all(job["status"] == "completed" and (job["conclusion"] == "success"
                or (job["name"] in allowed_skips and job["conclusion"] == "skipped")) for job in jobs),
            "a required job failed, skipped or was cancelled")
    tree = record["identity"]["tree_sha"]
    ui_devices = {meta["device"] for meta in metadata.values() if meta["tier"] == "ui"}
    ui_populations, ui_base = {}, []
    if context == "ui":
        require(ui is not None and ui_devices, "UI manifest and device populations are not admitted")
        require(all(meta["tier"] in {"ui", "ui-infrastructure"} for meta in metadata.values())
                and sum(meta["population"] == "ui-archive" for meta in metadata.values()) == 1,
                "UI workflow needs one archive selection producer and device shards")
        for device in ui_devices:
            platform = DEVICES[device]
            ui_populations[device] = ui["populations"][device]
            assigned = [meta["shard"] for meta in metadata.values() if meta.get("device") == device]
            require(len(assigned) == len(set(assigned)) and set(assigned) == set(ui_populations[device]),
                    "workflow shard union differs from the admitted manifest")
            base_ui = record["ui_inputs"]["base"] or ui
            if cloud is None or device != "appletv":
                ui_base.extend(base_ui["base_populations"][device])
        for summary in summaries:
            require(summary["hashes"]["manifests"].get("ui-shards") == ui["manifest_sha256"], "UI manifest hash differs")
            meta = next((item for item in metadata.values() if all(item[key] == summary["run"][key]
                        for key in ("tier", "job", "shard"))), None)
            require(meta is not None, "unsupported UI summary job")
            if meta["tier"] == "ui":
                require(summary["hashes"]["manifests"].get("test-plan") == ui["plans"][DEVICES[meta["device"]]]["sha256"],
                        "UI default-plan hash differs")
    def population(meta):
        if meta["population"] == "gate-classification":
            return [test_identity("host", "Gate change classification")]
        if meta["population"] == "ui-archive":
            return [test_identity("host", "UI archive selection")]
        if meta["tier"] == "ui":
            return ui_populations[meta["device"]][meta["shard"]]
        return (record["operational_populations"][meta["population"]][meta["shard"]]
                if meta["tier"] == "build" else record["populations"][meta["population"]])
    required_jobs = [{"tier": meta["tier"], "job": meta["job"], "shard": meta["shard"],
                      "run_id": str(run["id"]), "attempt": actual[name]["evidence_attempt"],
                      "workflow_paths": [run["path"]], "expected": {"tree_sha": tree, "identities": population(meta)},
                      "status": actual[name]["status"], "conclusion": actual[name]["conclusion"]}
                     for name, meta in metadata.items() if name not in cloud_jobs]
    parts = ["host", "unit-ios", "unit-tvos"] if context == "gate" else []
    expected = [identity for part in parts for identity in record["populations"][part]]
    base_expected = [identity for part in parts for identity in record["base_populations"][part]]
    if context == "gate":
        required_operations = {"run_build"} | {meta["population"] for meta in metadata.values() if meta["tier"] == "build"}
        operations = [identity for operation, platforms in record["operational_populations"].items() if operation in required_operations
                      for identities in platforms.values() for identity in identities]
        expected += operations
        base_expected += operations
        infrastructure = [entry for meta in metadata.values() if meta["population"] == "gate-classification"
                          for entry in population(meta)]
        expected += infrastructure
        base_expected += infrastructure
    else:
        expected = [entry for job in required_jobs for entry in job["expected"]["identities"]]
        base_expected = ui_base + [test_identity("host", "UI archive selection")]
    inputs = {"expected": {"tree_sha": tree, "identities": expected}, "admission_identity": record["identity"],
              "required_jobs": required_jobs, "base_policy": record["base_policy"], "candidate_policy": record["candidate_policy"],
              "environment": "fixture" if context == "ui" else "hermetic", "approved_head": record["identity"].get("head_sha") if approved else None,
              "fork_originated": fork, "ci_changing": record["classification"]["ci_changing"],
              "app_affected": record["classification"]["app_affected"], "context": context,
              "base_population": {"base_sha": record["identity"].get("base_sha"), "identities": base_expected}}
    if context == "ui" and record.get("base_registry") is not None:
        evaluated_on = run.get("run_started_at", run.get("created_at", ""))[:10]
        require(date.fromisoformat(evaluated_on).isoformat() == evaluated_on, "trusted UI evaluation date is missing")
        inputs.update(base_registry=record["base_registry"], evaluated_on=evaluated_on)
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
    result = {"state": "success" if verdict["status"] in {"passed", "not-applicable"} else "failure",
            "description": ("Checks passed; app build and unit jobs not applicable" if verdict.get("not_applicable") else
                            "All required jobs and admitted populations passed") if verdict["status"] == "passed" else
                           "Not applicable: trusted classification cannot affect the app" if verdict["status"] == "not-applicable" else "Base gate refused incomplete or invalid evidence",
            "source": {"repository": record["identity"]["repository"], "workflow_path": run["path"],
                       "run_id": run["id"], "attempt": run["run_attempt"], "approval_based": verdict["approval_based"], "fork_originated": fork},
            "population": details, "expected_skips": verdict["expected_skips"], "deselected": verdict["deselected"],
            "removed_by_pr": verdict["removed_by_pr"]}
    if verdict.get("not_applicable"):
        result["not_applicable"] = verdict["not_applicable"]
    if cloud is not None:
        from ci_population import removed_tests
        from ci_xcode_cloud import applied_deselections
        deselected = applied_deselections(record, approved=approved)
        result["deselected"].extend(deselected)
        # Explicitly owned deselections remain declared; only absent methods
        # count as removals, matching the GitHub population report.
        tv_base = record["ui_inputs"]["base"]["base_populations"]["appletv"]
        result["removed_by_pr"].extend(removed_tests(
            {"base_sha": record["identity"]["base_sha"], "identities": tv_base},
            cloud["identities"] + [item["identity"] for item in deselected], base_sha=record["identity"]["base_sha"]))
        result["xcode_cloud"] = {key: value for key, value in cloud.items() if key != "identities"}
        result["population"].append({"tier": "ui", "shard": "appletv/xcode-cloud", "expected": len(cloud["identities"]),
                                     "compiled": None, "observed": len(cloud["identities"])})
        if result["state"] == "success":
            result["description"] = "GitHub iPhone/iPad and API-verified Xcode Cloud Apple TV populations passed"
    return result
