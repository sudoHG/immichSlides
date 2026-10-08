"""Throwaway hosted-only calibration; revert after recording the real run."""

import hashlib
import json
import plistlib
from datetime import date, timedelta
from pathlib import Path

import ci_flaky
import run_fixture_ui_tests as runner
from ci_summary import test_identity
from strict_e2e_runner_support import WRONG_PUBLIC_API_KEY

LISTED = "ScenePresentationContractUITests/testIPhoneSinglePhotoSharedScenePresentationContract"
UNLISTED = "ScenePresentationContractUITests/testIPhoneSmartFillSharedScenePresentationContract"


def activate():
    original_load = runner.load_registry
    original_export = runner.export_private_result_bundle

    def registry(root, revision):
        payload, _ = original_load(root, revision)
        today = date.today()
        payload["entries"].append({
            "identity": test_identity("ui", LISTED, platform="ios"),
            "scope": {"tier": "ui", "environment": "hermetic"},
            "issue": "https://github.com/sudoHG/immichSlides/issues/97",
            "owner": "sudoHG",
            "added_on": today.isoformat(),
            "review_by": (today + timedelta(days=1)).isoformat(),
            "symptom": "Throwaway calibration: first invocation uses the public wrong fixture key",
            "evidence": ["This temporary hosted run; not a permanent flaky-policy approval"],
        })
        ci_flaky.parse_registry(payload)
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        return payload, digest

    def export(bundle, output, secrets, **options):
        return original_export(bundle, output, [*secrets, WRONG_PUBLIC_API_KEY], **options)

    def attempts(command, registry, **options):
        execute = options["execute"]
        actual_calls = []
        original_run = Path(command[command.index("-xctestrun") + 1])
        payload = plistlib.loads(original_run.read_bytes())
        for configuration in payload["TestConfigurations"]:
            for target in configuration["TestTargets"]:
                if target.get("BlueprintName") == "immichSlidesUITests":
                    target["EnvironmentVariables"]["IMMICH_TEST_API_KEY"] = WRONG_PUBLIC_API_KEY
        wrong_run = original_run.with_name("calibration-first.xctestrun")
        wrong_run.write_bytes(plistlib.dumps(payload))

        def first_wrong(call):
            actual = list(call)
            if not actual_calls:
                actual[actual.index("-xctestrun") + 1] = str(wrong_run)
            actual_calls.append(actual)
            return execute(actual)

        result = ci_flaky.run_xcode_attempts(command, registry, **dict(options, execute=first_wrong))
        for invocation, actual in zip(result["invocations"], actual_calls):
            invocation["command"] = actual
        result["calibration"] = {
            "synthetic_registry": True, "listed": LISTED, "unlisted": UNLISTED,
            "first_input": "public wrong fixture key", "retry_input": "public valid fixture key",
        }
        return result

    runner.load_registry = registry
    runner.export_private_result_bundle = export
    runner.run_xcode_attempts = attempts
