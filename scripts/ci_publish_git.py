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
from xml.etree import ElementTree

import yaml

from ci_summary import ContractError, decode, identity_key, require, sha, test_identity
from ci_ui_shards import DEVICES, MANIFEST_PATH, default_plan_population, parse_shard_manifest, shard_populations

BASE_MODULES = ("ci_summary.py", "ci_population.py", "ci_verdict.py", "ui_test_inventory.py",
                "run_host_checks.py")
OPTIONAL_BASE_MODULES = ("ci_flaky.py", "ci_ui_shards.py", "ci_ui_selection.py", "ci_ui_packing.py", "ci_ui_test_kinds.py",
                         "ci_ui_discovery.py")
UI_WORKFLOW_PATH = ".github/workflows/ci-ui.yml"
# The only dynamic matrix value a UI producer may use; admission binds it to trusted shard names.
DYNAMIC_UI_SHARDS = {scope: "${{ fromJSON(needs.archive.outputs." + scope + "_shards) }}"
                     for scope in ("ios", "tvos", "iphone", "ipad", "appletv")}
SELECTION_UI_SHARDS = {scope: value.replace("needs.archive.", "needs.selection.")
                       for scope, value in DYNAMIC_UI_SHARDS.items()}
UI_CAPACITIES = {phase: {device: "${{ fromJSON(needs." + phase + ".outputs." + device + "_capacity) }}"
                        for device in DEVICES} for phase in ("archive", "selection")}
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
elif p['operation']=='host':
    from run_host_checks import host_partition
    result={'host-'+scope:host_partition(p['population'],scope) for scope in ('linux','macos')}
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
    if p.get('selection_inputs') is not None and 'error' not in result:
        try:
            from ci_ui_selection import select_ui_population
            from ci_summary import identity_key
            selection_inputs=p['selection_inputs']
            selection_options={}
            if p.get('pack_scoped_ui'):
                from ci_ui_selection import platform_sources_from_project
                from ci_ui_packing import pack_scoped_selection
                selection_options={'platform_scoped':True,'functional_only':True,
                    'platform_sources':platform_sources_from_project(selection_inputs['project']),
                    'expected_skips':selection_inputs.get('expected_skips',[])}
            selection=select_ui_population(selection_inputs['paths'],selection_inputs['classification_policy'],
                build_target_paths=selection_inputs['build_target_paths'],area_map=selection_inputs['area_map'],
                populations=p['populations'],plans={platform:entry['plan'] for platform,entry in p['plans'].items()},
                event=selection_inputs['event'],**selection_options)
            selection.update(map_revision=selection_inputs['map_revision'],map_sha256=selection_inputs['map_sha256'])
            selection['shards']={}
            for device,shards in result['populations'].items():
                selected={identity_key(entry) for entry in selection['populations'][device]}
                selection['shards'][device]={name:[entry for entry in entries if identity_key(entry) in selected]
                    for name,entries in shards.items()}
            if p.get('pack_scoped_ui') and selection['mode']=='scoped':
                packing=pack_scoped_selection(selection['populations'],selection_inputs['durations'],
                    **({'algorithm':'capacity-v2'} if p.get('scoped_ui_v2') else {}))
                selection.update(shards=packing['shards'],packing=packing)
            result['selection']=selection
        except Exception as error:
            result['selection']={'error':str(error)}
            if p.get('pack_scoped_ui'):
                result['error']='functional UI selection refused: '+str(error)
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
    base_listing, base_sources = tree_inputs(base)
    payload = {"operation": "derive", "sources": sources, "paths": paths,
               "classification_policy": json.loads(read_blob(base, "scripts/ci-classification.json")),
               "build_target_paths": sorted({entry["path"] for entry in listing + base_listing
                                             if entry["path"].startswith("immichSlides/")})}
    derived = base_reader(modules, payload)
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
    selection_inputs = None
    if "ci_ui_selection.py" in modules and any(entry["path"] == "scripts/ci-ui-areas.json" for entry in base_listing):
        raw_map = read_blob(base, "scripts/ci-ui-areas.json")
        selection_inputs = {"paths": paths, "classification_policy": payload["classification_policy"],
                            "build_target_paths": payload["build_target_paths"], "event": identity["event"],
                            "area_map": raw_map, "map_revision": base,
                            "map_sha256": hashlib.sha256(raw_map.encode()).hexdigest()}
        if "ci_ui_packing.py" in modules:
            from ci_ui_packing import DURATIONS_PATH
            base_paths = {entry["path"] for entry in base_listing if entry["type"] == "blob"
                          and entry["mode"] in {"100644", "100755"}}
            selection_inputs["project"] = (read_blob(base, "immichSlides.xcodeproj/project.pbxproj")
                                           if "immichSlides.xcodeproj/project.pbxproj" in base_paths else "")
            if DURATIONS_PATH in base_paths:
                selection_inputs["durations"] = read_blob(base, DURATIONS_PATH)
            selection_inputs["expected_skips"] = json.loads(read_blob(base, "scripts/ci-test-policy.json"))["expected_skips"]
    for side, revision, entries in (("base", base, base_listing), ("candidate", commit, listing)):
        try:
            ui[side] = ui_inputs(revision, entries, populations=derived["populations"],
                                 base_populations=base_derived["populations"],
                                 workflow=workflows.get(".github/workflows/ci-ui.yml", {}).get(side), run=run, modules=modules,
                                 selection_inputs=selection_inputs)
        except Exception as error:
            if side == "base":
                raise
            # Bad candidate UI data cannot suppress a separate gate admission.
            ui[side] = {"error": ui_failure_hint(error) or "candidate UI inputs are invalid"}
    if UI_WORKFLOW_PATH in workflows:
        for side in ("base", "candidate"):
            if ui.get(side) and "error" not in ui[side]:
                try:
                    workflows[UI_WORKFLOW_PATH][side] = bind_ui_shards(
                        workflows[UI_WORKFLOW_PATH][side], ui_shard_lists(ui[side], identity, derived["classification"]))
                    workflows[UI_WORKFLOW_PATH][side] = bind_ui_capacities(workflows[UI_WORKFLOW_PATH][side], ui[side])
                except (ContractError, KeyError, TypeError) as error:
                    # Invalid UI binding cannot suppress the independent gate admission.
                    ui[side]["error"] = ("UI shard binding refused: " + str(error))[:500]
    cloud_inputs = None
    from ci_xcode_cloud import PLAN_PATH, SCHEME_PATH
    cloud_paths = {PLAN_PATH, SCHEME_PATH, "scripts/strict_e2e_server.py", "ci_scripts/fixture_server.py"}
    candidate_paths = {entry["path"] for entry in listing if entry["type"] == "blob" and entry["mode"] in {"100644", "100755"}}
    if identity["event"] == "pull_request" and cloud_paths <= candidate_paths:
        head = identity["head_sha"]
        head_listing, _ = tree_inputs(head)
        head_paths = {entry["path"] for entry in head_listing
                      if entry["type"] == "blob" and entry["mode"] in {"100644", "100755"}}
        # Cloud checks out on a case-insensitive filesystem; no head path may
        # shadow another plan, scheme, hook or source while retaining its hash.
        unambiguous = len({entry["path"].casefold() for entry in head_listing}) == len(head_listing)
        if cloud_paths <= head_paths and unambiguous:
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
    cloud_v2_inputs = None
    from ci_xcode_cloud_groups import REGISTRY_PATH, snapshot
    if identity["event"] == "pull_request" and any(entry["path"] == REGISTRY_PATH for entry in base_listing):
        try:
            head_listing, _ = tree_inputs(identity["head_sha"])
            cloud_v2_inputs = snapshot(base, identity["head_sha"], base_listing, head_listing, read_blob,
                                       git("rev-parse", identity["head_sha"] + "^{tree}"))
        except (ContractError, KeyError, TypeError, ValueError, ElementTree.ParseError):
            # Invalid Cloud eligibility must not suppress complete GitHub evidence.
            cloud_v2_inputs = {"error": "Cloud trusted inputs differ or are unsupported; run GitHub"}
    return {"schema_version": 1, "run_id": run["id"], "workflow_id": run["workflow_id"],
            "workflow_path": run["path"], "identity": identity, "tree_listing": listing,
            "populations": derived["populations"], "base_populations": base_derived["populations"],
            "operational_populations": operational,
            "ui_inputs": ui,
            "cloud_inputs": cloud_inputs,
            "cloud_v2_inputs": cloud_v2_inputs,
            "classification": derived["classification"], "reader_revision": base, "workflows": workflows,
            "base_registry": json.loads(read_blob(base, "scripts/ci-known-flaky.json"))
                             if any(entry["path"] == "scripts/ci-known-flaky.json" for entry in base_listing) else None,
            "base_policy": json.loads(read_blob(base, "scripts/ci-test-policy.json")),
            "candidate_policy": json.loads(read_blob(commit, "scripts/ci-test-policy.json"))}


def ui_matrices(source):
    """(job, matrix) for UI shard matrices, without expanding them."""
    from check_workflow_policy import WorkflowLoader
    workflow = yaml.load(source, Loader=WorkflowLoader)
    require(isinstance(workflow, dict) and isinstance(workflow.get("jobs"), dict), "workflow needs literal jobs")
    return [(job, job["strategy"]["matrix"]) for job in workflow["jobs"].values()
            if isinstance(job, dict) and isinstance(job.get("strategy"), dict)
            and isinstance(job["strategy"].get("matrix"), dict) and "shard" in job["strategy"]["matrix"]]


def ui_workflow_devices(source):
    return {device for _, matrix in ui_matrices(source) for device in matrix.get("device", []) if device in DEVICES}


def bind_ui_shards(source, shards):
    """Replace each producer's dynamic shard list with the admitted trusted list.

    Only `shard: ${{ fromJSON(needs.archive.outputs.<platform>_shards) }}` beside a literal
    device list of that one platform is accepted; the rest of the text stays byte-identical.
    """
    if source is None:
        return None
    counts = {}
    for _, matrix in ui_matrices(source):
        if not isinstance(matrix["shard"], str):
            continue
        devices = matrix.get("device")
        require(isinstance(devices, list) and devices and all(device in DEVICES for device in devices)
                and len({DEVICES[device] for device in devices}) == 1, "dynamic UI shards need one literal platform")
        platform = DEVICES[devices[0]]
        supported = [values for values in (DYNAMIC_UI_SHARDS, SELECTION_UI_SHARDS) if matrix["shard"] in values.values()]
        require(len(supported) == 1, "unsupported dynamic UI shard list")
        expressions = supported[0]
        scope = devices[0] if len(devices) == 1 and matrix["shard"] == expressions[devices[0]] else platform
        require(matrix["shard"] == expressions[scope], "unsupported dynamic UI shard list")
        chosen = [shards[device] if device in shards else shards[platform] for device in devices]
        require(all(item == chosen[0] for item in chosen), "devices sharing a matrix select different shards")
        expression = expressions[scope]
        if expression in counts:
            require(counts[expression][1] == chosen[0], "one UI output binds different shard lists")
        counts[expression] = (counts.get(expression, (0, []))[0] + 1, chosen[0])
    for expression, (count, chosen) in counts.items():
        require(source.count(expression) == count, "dynamic UI shard list outside its matrix")
        require(all(re.fullmatch(r"[a-z][a-z0-9-]*", shard) for shard in chosen), "invalid UI shard name")
        source = source.replace(expression, "[" + ", ".join(chosen) + "]")
    return source


def ui_shard_lists(ui, identity, classification):
    """Shards a producer must run per platform: the non-empty trusted selection, or every manifest shard."""
    order = list(ui["manifest"]["shards"])
    selection = ui.get("selection") or {}
    if not (identity["event"] == "pull_request" and (classification.get("ci_changing") is False
            or selection.get("coverage") == "functional")
            and selection.get("mode") in {"scoped", "none"}):
        return {platform: order for platform in ("ios", "tvos")}
    if selection.get("packing"):
        return {device: [shard for shard, entries in shards.items() if entries]
                for device, shards in selection["shards"].items()}
    lists = {}
    for platform in ("ios", "tvos"):
        chosen = [[shard for shard in order
                   if selection["mode"] == "scoped" and selection["shards"][device][shard]]
                  for device in sorted(selection.get("shards", {})) if DEVICES[device] == platform]
        require(all(item == chosen[0] for item in chosen), "devices of one platform select different shards")
        lists[platform] = chosen[0] if chosen else []
    return lists


def ui_capacities(ui):
    """A reviewed scoped plan owns capacities; full runs retain the original limits."""
    from ci_ui_packing import DEVICE_SLOTS, V2_MACOS_SLOTS, V2_DEVICE_MAX_SLOTS
    packing = (ui.get("selection") or {}).get("packing") or {}
    capacities = (packing["capacity"]["device_slots"] if packing.get("algorithm") == "capacity-v2"
                  else DEVICE_SLOTS)
    require(set(capacities) == set(DEVICES) and all(type(value) is int and 1 <= value <= V2_DEVICE_MAX_SLOTS[device]
            for device, value in capacities.items()) and sum(capacities.values()) <= V2_MACOS_SLOTS,
            "trusted UI capacity exceeds five hosted slots")
    return dict(capacities)


def bind_ui_capacities(source, ui):
    """Bind only device-specific capacity outputs, never evaluate workflow expressions."""
    if source is None:
        return None
    from check_workflow_policy import WorkflowLoader
    from ci_ui_packing import ACCELERATION_INTENT
    workflow = yaml.load(source, Loader=WorkflowLoader)
    accelerated = scoped_acceleration_intent(source)
    expected, counts, devices_seen = ui_capacities(ui), {}, set()
    for job, matrix in ui_matrices(source):
        capacity = job["strategy"].get("max-parallel")
        if not accelerated and (capacity is None or type(capacity) is int):
            continue
        devices = matrix.get("device")
        require(accelerated and isinstance(devices, list) and len(devices) == 1 and devices[0] in DEVICES,
                "dynamic UI capacity needs one literal device and scoped acceleration")
        device = devices[0]
        require(device not in devices_seen, "duplicate UI capacity device")
        devices_seen.add(device)
        phases = [phase for phase, values in UI_CAPACITIES.items() if capacity == values[device]]
        require(len(phases) == 1, "unsupported dynamic UI capacity")
        owner = workflow["jobs"].get(phases[0])
        require(isinstance(owner, dict) and isinstance(owner.get("outputs"), dict)
                and owner["outputs"].get(device + "_capacity")
                == "${{ steps.select.outputs." + device + "_capacity }}", "UI capacity output is not selection-owned")
        selectors = [step for step in owner.get("steps", []) if step.get("id") == "select"]
        require(len(selectors) == 1 and any(script == "ci_ui_tests.py" and arguments
                and arguments[0] in {"wait-archive", "select"} and ACCELERATION_INTENT in arguments
                for script, arguments in producer_commands(selectors[0].get("run", ""))),
                "UI capacity output does not come from its accelerated selection command")
        counts[capacity] = expected[device]
    if accelerated:
        require(devices_seen == set(DEVICES), "scoped acceleration requires three independently bound capacities")
    for expression, capacity in counts.items():
        require(source.count(expression) == 1, "dynamic UI capacity outside its strategy")
        source = source.replace(expression, str(capacity))
    return source


def ui_failure_hint(error):
    message = str(error)
    if message.startswith("functional UI selection refused: "):
        return message[:500]
    if message == "workflow is absent on the base; exact-head approval required":
        return message
    if re.fullmatch(r"shard [a-z][a-z0-9-]* has no tests on (?:iphone|ipad|appletv); "
                    r"update scripts/ci-ui-shards\.json", message):
        return message
    return None


def ui_inputs(revision, listing, *, populations=None, base_populations=None, workflow=None, run=None, modules=None,
              selection_inputs=None):
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
        bound = bind_ui_shards(workflow, {platform: list(result["manifest"]["shards"]) for platform in ("ios", "tvos")})
        _, _, _, metadata = workflow_contract(bound, run, metadata=True)
        devices = sorted({meta["device"] for meta in metadata.values() if meta["tier"] == "ui"})
        require(all(DEVICES[device] in result["plans"] for device in devices), "UI workflow device has no default plan")
    if modules is not None:
        computed = base_reader(modules, {"operation": "ui", "shard_devices": devices,
                      "devices": sorted(device for device, platform in DEVICES.items() if platform in result["plans"]), "populations": populations,
                      "base_populations": base_populations, "plans": result["plans"], "manifest": result["manifest"],
                      "selection_inputs": selection_inputs,
                      "pack_scoped_ui": scoped_packing_intent(workflow) if workflow is not None else False,
                      "scoped_ui_v2": scoped_acceleration_intent(workflow) if workflow is not None else False})
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


def scoped_packing_intent(source):
    """Only one literal selection command can activate the successor protocol."""
    from ci_ui_packing import PACKING_INTENT
    from check_workflow_policy import WorkflowLoader
    workflow = yaml.load(source, Loader=WorkflowLoader)
    require(isinstance(workflow, dict) and isinstance(workflow.get("jobs"), dict), "workflow needs literal jobs")
    matches = [(script, arguments) for job in workflow["jobs"].values() for step in job.get("steps", [])
               for script, arguments in producer_commands(step.get("run", "")) if PACKING_INTENT in arguments]
    require(not matches or len(matches) == 1 and matches[0][0] == "ci_ui_tests.py"
            and matches[0][1][0] in {"wait-archive", "select"} and matches[0][1].count(PACKING_INTENT) == 1,
            "unsupported scoped UI packing intent")
    require(source.count(PACKING_INTENT) == len(matches), "scoped UI packing intent outside archive selection")
    return bool(matches)


def scoped_acceleration_intent(source):
    """Only a literal packed selection opts into the base-owned five-slot model."""
    from ci_ui_packing import ACCELERATION_INTENT, PACKING_INTENT
    from check_workflow_policy import WorkflowLoader
    workflow = yaml.load(source, Loader=WorkflowLoader)
    require(isinstance(workflow, dict) and isinstance(workflow.get("jobs"), dict), "workflow needs literal jobs")
    matches = [(script, arguments) for job in workflow["jobs"].values() for step in job.get("steps", [])
               for script, arguments in producer_commands(step.get("run", "")) if ACCELERATION_INTENT in arguments]
    require(not matches or len(matches) == 1 and matches[0][0] == "ci_ui_tests.py"
            and matches[0][1][0] in {"wait-archive", "select"} and matches[0][1].count(ACCELERATION_INTENT) == 1
            and PACKING_INTENT in matches[0][1] and scoped_packing_intent(source),
            "unsupported scoped UI acceleration intent")
    require(source.count(ACCELERATION_INTENT) == len(matches), "scoped UI acceleration intent outside selection")
    if matches:
        from ci_ui_discovery import DISCOVERY_INTENT
        shards = [arguments for job in workflow["jobs"].values() for step in job.get("steps", [])
                  for script, arguments in producer_commands(step.get("run", ""))
                  if script == "ci_ui_tests.py" and arguments and arguments[0] == "run"]
        require(shards and all(arguments.count(DISCOVERY_INTENT) == 1
                and not any(item.startswith(DISCOVERY_INTENT + "=") for item in arguments) for arguments in shards),
                "scoped UI acceleration requires official discovery on every shard command")
    return bool(matches)


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
            host_commands = [arguments for script, arguments in commands if script == "run_host_checks.py"]
            if host_commands:
                require(len(host_commands) == 1, "one literal host producer required")
                arguments = host_commands[0]
                indexes = [index for index, item in enumerate(arguments) if item == "--host-platform"]
                require(not any(item.startswith("--host-platform=") for item in arguments), "literal host platform required")
                if indexes:
                    require(len(indexes) == 1 and indexes[0] + 1 < len(arguments)
                            and arguments[indexes[0] + 1] in {"linux", "macos"}, "literal host platform required")
                    host = "host-" + arguments[indexes[0] + 1]
                    producers.append({"tier": "host", "job": host, "shard": None, "population": host})
                else:
                    producers.append({"tier": "host", "job": "host-checks", "shard": None, "population": "host"})
            if any(script == "ci_gate.py" and arguments and arguments[0] == "classify"
                   for script, arguments in commands):
                producers.append({"tier": "gate-infrastructure", "job": "gate-classification", "shard": None,
                                  "population": "gate-classification"})
            ui_operations = [(arguments[0], arguments) for script, arguments in commands
                             if script == "ci_ui_tests.py" and arguments and arguments[0] in {"wait-archive", "wait-cloud", "select", "wait-group", "run"}]
            for operation, arguments in ui_operations:
                if operation == "wait-archive":
                    producers.append({"tier": "ui-infrastructure", "job": "ui-archive", "shard": None, "population": "ui-archive"})
                elif operation == "wait-cloud":
                    producers.append({"tier": "ui-infrastructure", "job": "ui-cloud-wait", "shard": None, "population": "ui-cloud-wait"})
                elif operation == "select":
                    producers.append({"tier": "ui-infrastructure", "job": "ui-selection", "shard": None, "population": "ui-selection"})
                elif operation == "wait-group":
                    indexes = [index for index, item in enumerate(arguments) if item == "--group"]
                    require(len(indexes) == 1 and indexes[0] + 1 < len(arguments)
                            and arguments[indexes[0] + 1] in {"ios", "tvos"}, "literal Cloud group required")
                    group = arguments[indexes[0] + 1]
                    producers.append({"tier": "ui-infrastructure", "job": "ui-cloud-wait-" + group,
                                      "shard": None, "population": "ui-cloud-wait-" + group})
                else:
                    def option(name):
                        indexes = [index for index, item in enumerate(arguments) if item == name]
                        require(len(indexes) == 1 and indexes[0] + 1 < len(arguments), "literal UI device/shard required")
                        return arguments[indexes[0] + 1]
                    device, shard = option("--device"), option("--shard")
                    require(device in DEVICES and re.fullmatch(r"[a-z][a-z0-9-]*", shard), "unknown UI device/shard")
                    from ci_ui_discovery import DISCOVERY_INTENT
                    require(arguments.count(DISCOVERY_INTENT) <= 1
                            and not any(item.startswith(DISCOVERY_INTENT + "=") for item in arguments),
                            "unsupported official UI discovery intent")
                    meta = {"tier": "ui", "job": "ui-" + device, "shard": shard,
                            "population": "ui-" + DEVICES[device], "device": device}
                    if DISCOVERY_INTENT in arguments:
                        meta["official_discovery"] = True
                    producers.append(meta)
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


def ui_empty_selection_jobs(record, run, metadata, source=None):
    if record is None or run["path"] != ".github/workflows/ci-ui.yml":
        return set()
    ui = record.get("ui_inputs", {}).get("base") or {}
    selection = ui.get("selection") or {}
    if (selection.get("mode") != "scoped" or record["identity"]["event"] != "pull_request"
            or record["classification"].get("ci_changing") is not False and selection.get("coverage") != "functional"):
        return set()
    require(selection["map_revision"] == record["identity"]["base_sha"], "UI area map differs from admitted base")
    # A bound platform without selected shards declares its devices but expands no job.
    devices = (ui_workflow_devices(source) if source is not None
               else {meta["device"] for meta in metadata.values() if meta["tier"] == "ui"})
    require(devices == set(DEVICES), "scoped UI requires all three devices")
    return {name for name, meta in metadata.items() if meta["tier"] == "ui"
            and selection["shards"][meta["device"]][meta["shard"]] == []}


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
    from ci_xcode_cloud_groups import cloud_devices, selection as cloud_selection, canonical_hash
    external_devices = cloud_devices(cloud)
    group_cloud = cloud is not None and cloud.get("schema_version") == 2
    if cloud is not None:
        from ci_xcode_cloud import admitted_population
        require(context == "ui" and not fork and record["identity"]["event"] == "pull_request",
                "external Cloud evidence cannot cover this source")
        if group_cloud:
            external_population = []
            for group, proof in cloud["groups"].items():
                attempt = proof["evidence_attempt"]
                require(type(attempt) is int and 0 < attempt <= run["run_attempt"], "Cloud group evidence attempt differs")
                descriptor = cloud_selection(record, dict(run, run_attempt=attempt), group, approved=approved)
                entries = sorted([entry for identities in descriptor["populations"].values() for entry in identities], key=identity_key)
                require(proof["group"] == group and proof["identities"] == entries
                        and proof["selection_sha256"] == canonical_hash(descriptor), "external Cloud selection differs")
                external_population.extend(entries)
            require(cloud["identities"] == sorted(external_population, key=identity_key), "Cloud group union differs")
        else:
            require(cloud.get("schema_version", 1) == 1 and cloud["identities"] == admitted_population(record, approved=approved),
                    "external Apple TV population differs")
        cloud_jobs = {name for name, meta in metadata.items() if meta.get("device") in external_devices}
        require(cloud_jobs and all(actual[name]["status"] == "completed" and actual[name]["conclusion"] == "skipped"
                and (actual[name].get("runner_id") is None or type(actual[name].get("runner_id")) is int
                     and actual[name]["runner_id"] == 0) and actual[name].get("steps") == [] for name in cloud_jobs),
                "routed GitHub device shards must be unexecuted literal skips")
        require(not any(summary["run"]["job"] in {"ui-" + device for device in external_devices} for summary in summaries),
                "mixed GitHub and Xcode Cloud evidence within a platform group")
        allowed_skips |= cloud_jobs
    tree = record["identity"]["tree_sha"]
    ui_devices = ui_workflow_devices(source) if context == "ui" else set()
    ui_populations, ui_base = {}, []
    ui_mode, empty_jobs = "full", set()
    if context == "ui":
        require(ui is not None and ui_devices, "UI manifest and device populations are not admitted")
        require(all(meta["tier"] in {"ui", "ui-infrastructure"} for meta in metadata.values())
                and sum(meta["population"] in {"ui-archive", "ui-selection"} for meta in metadata.values()) == 1,
                "UI workflow needs one selection producer and device shards")
        selection = ui.get("selection") or {}
        if scoped_acceleration_intent(source):
            capacities = ui_capacities(ui)
            matrices = ui_matrices(source)
            require(len(matrices) == 3 and {tuple(matrix.get("device", [])) for _, matrix in matrices}
                    == {(device,) for device in DEVICES}, "accelerated UI needs three literal device matrices")
            require(all(type(job["strategy"].get("max-parallel")) is int
                        and job["strategy"]["max-parallel"] == capacities[matrix["device"][0]]
                        for job, matrix in matrices), "UI capacity differs from its trusted plan")
        if any(meta["population"] == "ui-selection" for meta in metadata.values()):
            require(selection.get("coverage") == "functional" and selection.get("packing")
                    and selection.get("map_revision") == record["identity"]["base_sha"],
                    "group selection infrastructure needs a trusted packed functional plan")
        scoped_selection = (selection.get("mode") == "scoped" and (cloud is None or group_cloud)
                            and record["identity"]["event"] == "pull_request"
                            and (record["classification"]["ci_changing"] is False
                                 or selection.get("coverage") == "functional"))
        packed_selection = scoped_selection and selection.get("packing") is not None
        for device in ui_devices:
            platform = DEVICES[device]
            ui_populations[device] = ui["populations"][device]
            assigned = [meta["shard"] for meta in metadata.values() if meta.get("device") == device]
            # A dynamic producer schedules only the non-empty selected shards.
            selected = ({shard for shard, entries in selection["shards"][device].items() if entries}
                        if scoped_selection else None)
            require(len(assigned) == len(set(assigned)) and (set(assigned) == selected if packed_selection else
                    set(assigned) in (set(ui_populations[device]), selected)),
                    "workflow shard union differs from the admitted manifest")
            base_ui = record["ui_inputs"]["base"] or ui
            if device not in external_devices:
                ui_base.extend(base_ui["base_populations"][device])
        full_population = [entry for device, shards in ui_populations.items() if device not in external_devices
                           for entries in shards.values() for entry in entries]
        declared = [entry for summary in summaries if summary["run"]["tier"] == "ui"
                    for entry in summary["population"]["declared"]]
        if packed_selection or {identity_key(entry) for entry in declared} != {identity_key(entry) for entry in full_population}:
            selection = ui.get("selection") or {}
            require(selection.get("mode") == "scoped" and (cloud is None or group_cloud)
                    and record["identity"]["event"] == "pull_request"
                    and (record["classification"]["ci_changing"] is False or selection.get("coverage") == "functional"),
                    "UI population differs from full population and trusted selection")
            require(selection["map_revision"] == record["identity"]["base_sha"], "UI area map differs from admitted base")
            require(ui_devices == set(DEVICES), "scoped UI requires all three devices")
            ui_populations = selection["shards"]
            ui_mode = "scoped"
            empty_jobs = {name for name, meta in metadata.items() if meta["tier"] == "ui"
                          and not ui_populations[meta["device"]][meta["shard"]]}
            require(all(actual[name]["status"] == "completed" and actual[name]["conclusion"] == "skipped"
                        and (actual[name].get("runner_id") is None or type(actual[name].get("runner_id")) is int
                             and actual[name]["runner_id"] == 0) and actual[name].get("steps") == []
                        for name in empty_jobs), "empty scoped UI shards must be unexecuted literal skips")
            allowed_skips |= empty_jobs
        for summary in summaries:
            require(summary["hashes"]["manifests"].get("ui-shards") == ui["manifest_sha256"], "UI manifest hash differs")
            if packed_selection:
                require(summary["hashes"]["manifests"].get("ui-scoped-plan") == selection["packing"]["sha256"],
                        "scoped UI plan hash differs")
            meta = next((item for item in metadata.values() if all(item[key] == summary["run"][key]
                        for key in ("tier", "job", "shard"))), None)
            require(meta is not None, "unsupported UI summary job")
            if meta["tier"] == "ui":
                require(summary["hashes"]["manifests"].get("test-plan") == ui["plans"][DEVICES[meta["device"]]]["sha256"],
                        "UI default-plan hash differs")
                discovery = bool(meta.get("official_discovery") and packed_selection
                                 and selection.get("coverage") == "functional")
                if discovery:
                    from ci_ui_discovery import discovery_eligible
                    discovery = discovery_eligible(ui_populations[meta["device"]][meta["shard"]], record["base_policy"])
                require(summary["schema_version"] == (2 if discovery else 1),
                        "UI compilation evidence differs from its admitted workflow protocol")
    require(all(job["status"] == "completed" and (job["conclusion"] == "success"
                or (job["name"] in allowed_skips and job["conclusion"] == "skipped")) for job in jobs),
            "a required job failed, skipped or was cancelled")
    modules, host_parts = None, {}
    split_hosts = [meta["population"] for meta in metadata.values() if meta["tier"] == "host"]
    if any(part in {"host-linux", "host-macos"} for part in split_hosts):
        require(context == "gate" and sorted(split_hosts) == ["host-linux", "host-macos"],
                "split host checks need exactly one Linux and one macOS producer")
        modules = trusted_reader(record)
        host_parts = base_reader(modules, {"operation": "host", "population": record["populations"]["host"]})
    def population(meta):
        if meta["population"] in host_parts:
            return host_parts[meta["population"]]
        if meta["population"] == "gate-classification":
            return [test_identity("host", "Gate change classification")]
        if meta["population"] == "ui-archive":
            return [test_identity("host", "UI archive selection")]
        if meta["population"] == "ui-cloud-wait":
            return [test_identity("host", "Apple TV cloud selection")]
        if meta["population"] == "ui-selection":
            return [test_identity("host", "UI selection")]
        if meta["population"] in {"ui-cloud-wait-ios", "ui-cloud-wait-tvos"}:
            return [test_identity("host", "UI cloud selection (" + meta["population"].removeprefix("ui-cloud-wait-") + ")")]
        if meta["tier"] == "ui":
            return ui_populations[meta["device"]][meta["shard"]]
        return (record["operational_populations"][meta["population"]][meta["shard"]]
                if meta["tier"] == "build" else record["populations"][meta["population"]])
    required_jobs = [{"tier": meta["tier"], "job": meta["job"], "shard": meta["shard"],
                      "run_id": str(run["id"]), "attempt": actual[name]["evidence_attempt"],
                      "workflow_paths": [run["path"]], "expected": {"tree_sha": tree, "identities": population(meta)},
                      "status": actual[name]["status"], "conclusion": actual[name]["conclusion"]}
                     for name, meta in metadata.items() if name not in cloud_jobs | empty_jobs]
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
        base_expected = ui_base + [entry for meta in metadata.values() if meta["tier"] == "ui-infrastructure" for entry in population(meta)]
        if ui_mode == "scoped":
            selected_tokens = {identity_key(entry) for entry in expected}
            base_expected = [entry for entry in base_expected if identity_key(entry) in selected_tokens]
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
    modules = modules if modules is not None else trusted_reader(record)
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
    if context == "ui":
        result["ui_population_mode"] = ui_mode
        if ui_mode == "scoped":
            if result["state"] == "success":
                result["description"] = "Trusted scoped UI population and required jobs passed"
            from ci_population import removed_tests
            # An unselected test is still present; selection is never a removal.
            result["removed_by_pr"] = removed_tests(
                {"base_sha": record["identity"]["base_sha"], "identities": ui_base},
                full_population, base_sha=record["identity"]["base_sha"])
    if verdict.get("not_applicable"):
        result["not_applicable"] = verdict["not_applicable"]
    if group_cloud:
        from ci_population import removed_tests
        result["xcode_cloud"] = {"schema_version": 2, "groups": {
            group: {key: value for key, value in proof.items() if key != "identities"}
            for group, proof in cloud["groups"].items()}}
        for device in sorted(external_devices):
            entries = [entry for entry in cloud["identities"] if entry["dimensions"]["device"] == device]
            result["population"].append({"tier": "ui", "shard": device + "/xcode-cloud",
                                         "expected": len(entries), "compiled": None, "observed": len(entries)})
            base_population = record["ui_inputs"]["base"]["base_populations"][device]
            present = [entry for shard in ui["populations"][device].values() for entry in shard]
            result["removed_by_pr"].extend(removed_tests(
                {"base_sha": record["identity"]["base_sha"], "identities": base_population},
                present, base_sha=record["identity"]["base_sha"]))
        if result["state"] == "success":
            result["description"] = "Trusted functional groups passed on GitHub and/or API-verified Xcode Cloud"
    elif cloud is not None:
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
