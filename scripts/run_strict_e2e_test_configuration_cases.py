"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from run_strict_e2e_test_fixtures import CommandError, PRIVATE_RESULT_BUNDLE_ROOT, Path, json, make_test_environment, mock, os, prepare_private_result_bundle_path, re, read_source_sha, reset_simulator_app, simulator_app_container, stat, subprocess, tempfile, write_case_manifest, write_fixture_artifacts

class StrictE2ERunnerTestsCasesConfiguration:


    def test_source_fingerprint_ignores_python_caches_but_tracks_source_changes(self):
        from strict_e2e_build import source_fingerprint
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "__pycache__").mkdir()
            source = root / "source.swift"
            cache = root / "__pycache__/source.cpython.pyc"
            loose_cache = root / "loose.pyc"
            for path in (source, cache, loose_cache):
                path.write_text("initial")
            with mock.patch("strict_e2e_build.subprocess.check_output", return_value=b"source.swift\0__pycache__/source.cpython.pyc\0loose.pyc\0"):
                initial = source_fingerprint(root)
                cache.write_text("generated cache changed")
                loose_cache.unlink()
                self.assertEqual(source_fingerprint(root), initial)
                source.write_text("source changed")
                self.assertNotEqual(source_fingerprint(root), initial)

    def test_private_result_bundles_use_the_system_temporary_directory(self) -> None:
        self.assertEqual(
            PRIVATE_RESULT_BUNDLE_ROOT,
            Path(tempfile.gettempdir()) / "immichSlides-strict-e2e-private",
        )
        with tempfile.TemporaryDirectory() as raw_directory:
            private_root = Path(raw_directory) / "private"
            with mock.patch("run_strict_e2e.PRIVATE_RESULT_BUNDLE_ROOT", private_root):
                bundle_path = prepare_private_result_bundle_path("smoke")
            self.assertEqual(bundle_path.parent.parent, private_root)
            self.assertEqual(stat.S_IMODE(private_root.stat().st_mode), 0o700)


    def test_test_environment_keeps_inputs_in_runner_and_removes_forbidden_keys(self) -> None:
        source = {
            "PATH": os.environ.get("PATH", ""),
            "UI_TEST_RESET_STATE": "1",
            "IMMICH_TEST_SERVER_URL": "private",
            "IMMICH_TEST_URL": "private",
            "IMMICH_TEST_API_KEY": "private",
            "IMMICH_API_KEY": "private",
            "TEST_RUNNER_UI_TEST_RESET_STATE": "1",
            "TEST_RUNNER_IMMICH_TEST_SERVER_URL": "private",
            "TEST_RUNNER_IMMICH_TEST_URL": "private",
            "TEST_RUNNER_IMMICH_TEST_API_KEY": "private",
            "SIMCTL_CHILD_IMMICH_SERVER_URL": "private",
        }
        environment = make_test_environment(
            source,
            server_url="http://127.0.0.1:12345/api",
            public_key="public-key",
        )

        self.assertEqual(environment["STRICT_E2E_INPUT_SERVER_URL"], "http://127.0.0.1:12345/api")
        self.assertEqual(environment["STRICT_E2E_INPUT_PUBLIC_KEY"], "public-key")
        self.assertEqual(environment["STRICT_E2E_INPUT_SCENARIO"], "normal")
        self.assertFalse(any(key.startswith("UI_TEST_") for key in environment))
        self.assertNotIn("IMMICH_TEST_SERVER_URL", environment)
        self.assertNotIn("IMMICH_TEST_API_KEY", environment)
        for key in ("IMMICH_TEST_URL", "TEST_RUNNER_IMMICH_TEST_URL", "IMMICH_API_KEY"):
            with self.subTest(key=key):
                self.assertNotIn(key, environment)
        self.assertEqual(set(environment), {
            "PATH", "STRICT_E2E_INPUT_SERVER_URL", "STRICT_E2E_INPUT_PUBLIC_KEY", "STRICT_E2E_INPUT_SCENARIO",
        })

    def test_simulator_app_container_distinguishes_absent_from_device_error(self) -> None:
        from strict_e2e_runner_support import InfrastructureTimeout
        calls = []

        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            calls.append(command)
            result = mock.Mock()
            if command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 1
                result.stdout = ""
                result.stderr = "Unable to lookup in current state: Shutdown"
                return result
            result.returncode = 0
            result.stdout = ""
            result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run):
            with self.assertRaises(CommandError) as raised:
                simulator_app_container("SIM-UDID", "com.331works.immichSlides")
        self.assertIn("Could not determine whether the App container exists", str(raised.exception))
        self.assertIn("Shutdown", str(raised.exception))

        calls.clear()
        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch("run_strict_e2e.time.sleep"):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID", platform="tvos")
        self.assertNotIsInstance(raised.exception, InfrastructureTimeout)
        self.assertEqual(sum(command[2] == "get_app_container" for command in calls), 1)
        self.assertFalse(any(command[2] in ("terminate", "uninstall", "keychain", "privacy") for command in calls))

        def absent_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.returncode = 2
            result.stdout = ""
            result.stderr = "No such container"
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=absent_run):
            self.assertIsNone(simulator_app_container("SIM-UDID", "com.331works.immichSlides"))


    def test_reset_simulator_app_stops_on_second_uninstall_failure(self) -> None:
        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "uninstall"]:
                result.returncode = 149
                result.stderr = "Failed to uninstall: device service unavailable"
            elif command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 2
                result.stderr = "No such container"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID", platform="tvos")
        self.assertIn("Second uninstall failed", str(raised.exception))
        self.assertIn("uninstall_retry_exit=149", str(raised.exception))

    def test_reset_refuses_to_continue_with_keychain_or_privacy_state(self) -> None:
        from strict_e2e_runner_support import InfrastructureTimeout
        for failed_step in ("keychain", "privacy"):
            for retry_exit in (0, 1):
                for stderr, classification in (("", "empty"),
                        ("Service connection invalid /Users/private-name", "service-unavailable"),
                        ("Unable to perform request in current state: Shutdown", "device-unavailable"),
                        ("Permission denied https://private-host.local", "permission-denied"),
                        ("NSPOSIXErrorDomain private-value", "posix-error"),
                        ("com.apple.CoreSimulator.SimError private-value", "simulator-error"),
                        ("private-value", "unclassified")):
                    with self.subTest(step=failed_step, retry_exit=retry_exit, classification=classification):
                        calls, reset_calls, clock = [], [], [0.0]

                        def fake_run(command, **kwargs):
                            calls.append(command)
                            code = 2 if command[2] == "get_app_container" else 0
                            if command[2] == failed_step:
                                reset_calls.append(command)
                                self.assertLessEqual(kwargs["timeout"], min(60, 120 - clock[0]))
                                clock[0] += 10
                                code = 1 if len(reset_calls) == 1 else retry_exit
                            return subprocess.CompletedProcess(command, code, "", stderr if code == 1 else "")

                        with mock.patch("run_strict_e2e.subprocess.run", side_effect=fake_run), mock.patch(
                            "run_strict_e2e.time.monotonic", side_effect=lambda: clock[0]
                        ), mock.patch("run_strict_e2e.time.sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                                mock.patch("builtins.print") as report:
                            if retry_exit:
                                with self.assertRaisesRegex(CommandError, f"Simulator {failed_step} reset failed") as raised:
                                    reset_simulator_app("SIM-UDID", platform="tvos")
                                log = str(raised.exception)
                                if failed_step == "keychain":
                                    self.assertFalse(any(command[2] == "privacy" for command in calls))
                            else:
                                log = reset_simulator_app("SIM-UDID", platform="tvos")
                        published = "\n".join(call.args[0] for call in report.call_args_list)
                        for output in (log, published):
                            self.assertIn(f"{failed_step}_reset_exit=1; stderr_class={classification}", output)
                            retry_class = classification if retry_exit else "empty"
                            self.assertIn(f"{failed_step}_reset_retry_exit={retry_exit}; stderr_class={retry_class}", output.splitlines())
                            self.assertNotIn("private", output)
                        expected = ["xcrun", "simctl", failed_step, "SIM-UDID", "reset", *(["all"] if failed_step == "privacy" else [])]
                        self.assertEqual([expected, expected], reset_calls)

        # The retry consumes the original reset deadline, including its one-second wait.
        clock, reset_calls = [0.0], []
        def exhausted(command, **kwargs):
            if command[2] == "privacy":
                reset_calls.append(command)
                clock[0] = 120
                return subprocess.CompletedProcess(command, 1, "", "private-value")
            return subprocess.CompletedProcess(command, 2 if command[2] == "get_app_container" else 0, "", "")
        with mock.patch("run_strict_e2e.subprocess.run", side_effect=exhausted), mock.patch(
            "run_strict_e2e.time.monotonic", side_effect=lambda: clock[0]
        ), mock.patch("run_strict_e2e.time.sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                mock.patch("builtins.print"), self.assertRaisesRegex(InfrastructureTimeout, "simulator-privacy-reset-retry timed out"):
            reset_simulator_app("SIM-UDID", platform="tvos")
        self.assertEqual(1, len(reset_calls))
        self.assertEqual(120, clock[0])

    def test_ios_reset_requires_disabled_password_autofill_after_isolation(self) -> None:
        import strict_e2e_runner_support as support
        inventory = json.dumps({"devices": {"runtime": [{"udid": "SIM-UDID", "dataPath": "/task-data/SIM-UDID"}]}})
        cases = [
            {}, {"prior": 90},
            {"write_exit": 1, "error": "Simulator password AutoFill disable failed"},
            {"read_exit": 1, "error": "Simulator password AutoFill readback failed"},
            {"readback": "true\n", "error": "Simulator password AutoFill readback failed"},
            {"readback": "0\n", "error": "Simulator password AutoFill readback failed"},
            {"readback": "", "error": "Simulator password AutoFill readback failed"},
            {"stored_type": "string", "error": "Simulator password AutoFill readback failed"},
            {"device_exit": 1, "error": "Simulator password AutoFill device lookup failed"},
            {"inventory": "invalid", "error": "Simulator password AutoFill device lookup returned invalid JSON"},
            {"inventory": '{"devices": {}}', "error": "Simulator password AutoFill device lookup did not identify one absolute data path"},
            {"inventory": inventory.replace("SIM-UDID", "OTHER"),
             "error": "Simulator password AutoFill device lookup did not identify one absolute data path"},
            {"inventory": inventory.replace('/task-data/', 'relative/'),
             "error": "Simulator password AutoFill device lookup did not identify one absolute data path"},
            {"write_seconds": 61, "error": "simulator-password-autofill-disable timed out after 58.0s"},
            {"prior": 90, "write_seconds": 31, "error": "simulator-password-autofill-disable timed out after 28.0s"},
            {"read_seconds": 61, "error": "simulator-password-autofill-readback timed out after 55.0s"},
            {"read_seconds": 61, "late_return": True,
             "error": "simulator-password-autofill timed out after 60.0s"},
            {"prior": 120, "error": "simulator-password-autofill-device timed out after 0.0s"},
            {"platform": "tvos"},
            {"platform": "iOS", "error": "Unsupported simulator platform"},
        ]
        for case in cases:
            with self.subTest(case=case):
                platform, error = case.get("platform", "ios"), case.get("error")
                clock = [100.0]
                calls = []

                def command(argv, **kwargs):
                    calls.append((argv, kwargs["timeout"]))
                    if argv[0] == "/usr/bin/plutil":
                        step, duration = "read", case.get("read_seconds", 1)
                        stdout = case.get("readback", "false\n")
                    elif argv[2] == "list":
                        step, duration = "device", 2
                        stdout = case.get("inventory", inventory)
                    elif argv[2] == "spawn":
                        step, duration, stdout = "write", case.get("write_seconds", 3), ""
                    else:
                        if argv[2] == "privacy":
                            clock[0] += case.get("prior", 0)
                        return subprocess.CompletedProcess(argv, 0, "", "")
                    if duration > kwargs["timeout"] and not case.get("late_return"):
                        clock[0] += kwargs["timeout"]
                        raise subprocess.TimeoutExpired(argv, kwargs["timeout"])
                    clock[0] += duration
                    exit_code = case.get(step + "_exit", 0)
                    if step == "read" and case.get("stored_type") == "string" and "bool" in argv:
                        exit_code = 1
                    return subprocess.CompletedProcess(argv, exit_code, stdout,
                                                       step + " fixture diagnostic\n")

                with mock.patch.object(support, "prepare_simulator", return_value=(None, "")) as prepare, \
                     mock.patch.object(support, "simulator_app_container", return_value=None), \
                     mock.patch.object(support.subprocess, "run", side_effect=command), \
                     mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
                     mock.patch.object(support.time, "sleep"):
                    if error:
                        with self.assertRaisesRegex(CommandError, re.escape(error)) as raised:
                            reset_simulator_app("SIM-UDID", platform=platform)
                        if case.get("write_exit"):
                            self.assertIn("password_autofill_write_exit=1; stderr='write fixture diagnostic'", str(raised.exception))
                        if "read_exit" in case or "readback" in case:
                            self.assertIn(f"password_autofill_read_exit={case.get('read_exit', 0)}; "
                                          f"stderr='read fixture diagnostic'; value={case.get('readback', 'false').strip()!r}",
                                          str(raised.exception))
                    else:
                        log = reset_simulator_app("SIM-UDID", platform=platform)
                        if platform == "ios":
                            self.assertIn("password_autofill=disabled;", log)
                            self.assertIn("password-autofill: passed; elapsed=6.000s;", log)
                    if platform not in ("ios", "tvos"):
                        prepare.assert_not_called()
                        self.assertEqual(calls, [])
                commands = [argv for argv, _ in calls]
                preference_calls = [argv for argv in commands if argv[2] == "spawn"]
                self.assertEqual(bool(preference_calls), platform == "ios" and case.get("prior", 0) < 120
                                 and not any(k in case for k in ("device_exit", "inventory")))
                if platform == "ios" and error is None:
                    self.assertEqual(preference_calls, [["xcrun", "simctl", "spawn", "SIM-UDID", "defaults",
                                                        "write", "com.apple.WebUI", "AutoFillPasswords", "-bool", "NO"]])
                    self.assertEqual(commands[-1], ["/usr/bin/plutil", "-extract", "AutoFillPasswords", "raw",
                                                   "-expect", "bool", "-o", "-",
                                                   "/task-data/SIM-UDID/Library/Preferences/com.apple.WebUI.plist"])
                    budget = min(support.SIMULATOR_COMMAND_TIMEOUT_SECONDS,
                                 support.SIMULATOR_RESET_TIMEOUT_SECONDS - case.get("prior", 0))
                    self.assertEqual([timeout for _, timeout in calls[-3:]], [budget, budget - 2, budget - 5])
                if preference_calls:
                    self.assertLess(next(i for i, argv in enumerate(commands) if argv[2] == "privacy"),
                                    next(i for i, argv in enumerate(commands) if argv[2] == "spawn"))

    def test_warm_products_and_per_case_environment_cannot_silently_change(self) -> None:
        import plistlib
        from strict_e2e_build import prepare_test_run, validate_warm_products

        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            products = root / "Build/Products"
            products.mkdir(parents=True)
            xctestrun = products / "strict.xctestrun"
            xctestrun.write_bytes(plistlib.dumps({
                "TestConfigurations": [{"TestTargets": [{
                    "BlueprintName": "immichSlidesUITests",
                    "EnvironmentVariables": {"LANG": "en_US.UTF-8", "STRICT_E2E_INPUT_SCENARIO": "old", "TEST_RUNNER_UI_TEST_RESET_STATE": "1"},
                    "UITargetAppEnvironmentVariables": {"UI_TEST_RESET_STATE": "1", "STRICT_E2E_INPUT_SERVER_URL": "stale"},
                }]}],
            }))
            from ci_build_archive import inventory
            receipt = {"products": inventory(products)}
            validate_warm_products(root, receipt)
            run = prepare_test_run(xctestrun, root / "case", {
                "STRICT_E2E_INPUT_SERVER_URL": "http://127.0.0.1:1234/api",
                "STRICT_E2E_INPUT_SCENARIO": "normal",
                "PATH": "kept out of test inputs",
            })
            target = plistlib.loads(run.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["EnvironmentVariables"], {
                "LANG": "en_US.UTF-8", "STRICT_E2E_INPUT_SERVER_URL": "http://127.0.0.1:1234/api", "STRICT_E2E_INPUT_SCENARIO": "normal",
            })
            self.assertEqual(target["UITargetAppEnvironmentVariables"], {})
            xctestrun.write_bytes(b"changed products")
            with self.assertRaises(CommandError):
                validate_warm_products(root, receipt)

    def test_warm_build_rejects_a_different_source_or_shard(self):
        from strict_e2e_build import load_warm_build, RECEIPT
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            identity = {"scheme": "immichSlides-iOS", "configuration": "Debug", "source_sha256": "a"}
            (root / RECEIPT).write_text(json.dumps({"schema_version": 1, "identity": identity}))
            for key in identity:
                with self.subTest(key=key), mock.patch("strict_e2e_build.workspace_preflight"), mock.patch(
                    "strict_e2e_build.shard_identity", return_value={**identity, key: "changed"}
                ), mock.patch("strict_e2e_build.validate_warm_products") as products:
                    with self.assertRaises(CommandError):
                        load_warm_build(root, "ios", "smoke", "Debug", "destination", root)
                    products.assert_not_called()


    def test_reset_simulator_app_stops_on_boot_failure_but_accepts_already_booted(self) -> None:
        def boot_fail(command: list[str], **kwargs: object) -> mock.Mock:
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "boot"]:
                result.returncode = 1
                result.stderr = "Unable to boot device in current state: Shutdown"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=boot_fail), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            with self.assertRaises(CommandError) as raised:
                reset_simulator_app("SIM-UDID", platform="tvos")
        self.assertIn("Simulator boot failed", str(raised.exception))

        calls: list[list[str]] = []

        def already_booted(command: list[str], **kwargs: object) -> mock.Mock:
            calls.append(command)
            result = mock.Mock()
            result.stdout = ""
            if command[:3] == ["xcrun", "simctl", "boot"]:
                result.returncode = 149
                result.stderr = "Unable to boot device in current state: Booted"
            elif command[:3] == ["xcrun", "simctl", "get_app_container"]:
                result.returncode = 2
                result.stderr = "No such container"
            else:
                result.returncode = 0
                result.stderr = ""
            return result

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=already_booted), mock.patch(
            "run_strict_e2e.time.sleep"
        ):
            log = reset_simulator_app("SIM-UDID", platform="tvos")
        self.assertIn("app_container=absent", log)
        self.assertIn("boot_exit=149", log)

        clock = [0.0]
        budgets = {}
        container_calls = []
        uninstalled = [False]

        def slow_boot(command, **kwargs):
            step = command[2]
            budgets[step] = kwargs["timeout"]
            if step in ("bootstatus", "terminate"):
                duration = 135 if step == "bootstatus" else 60
                clock[0] += min(duration, kwargs["timeout"])
                if duration > kwargs["timeout"]:
                    raise subprocess.TimeoutExpired(command, kwargs["timeout"])
            if step == "get_app_container":
                container_calls.append(command)
                if not uninstalled[0]:
                    duration = kwargs["timeout"] if len(container_calls) <= 3 else 5
                    clock[0] += duration
                    if len(container_calls) <= 3:
                        raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                    return subprocess.CompletedProcess(command, 0, "/sim/containers/immichSlides\n", "")
            if step == "uninstall":
                uninstalled[0] = True
            return subprocess.CompletedProcess(command, 2 if step == "get_app_container" else 0, "", "")

        with mock.patch("run_strict_e2e.subprocess.run", side_effect=slow_boot), mock.patch(
            "run_strict_e2e.time.monotonic", side_effect=lambda: clock[0]
        ), mock.patch("run_strict_e2e.time.sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            log = reset_simulator_app("SIM-UDID", platform="tvos")
        self.assertIn("app_container=absent", log)
        self.assertGreater(budgets["bootstatus"], 120)
        self.assertEqual(budgets["terminate"], 60)
        self.assertEqual(budgets["uninstall"], 60)
        self.assertEqual(budgets["privacy"], 59)
        self.assertIn("simulator-readiness: passed; attempts=4; elapsed=75.0s", log)


    def test_case_manifest_records_source_sha(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            evidence = Path(raw_directory)
            with mock.patch(
                "run_strict_e2e.subprocess.run",
                return_value=mock.Mock(returncode=0, stdout="08aa575ed2ff28cfb0a05c6315d1d4c416440069\n", stderr=""),
            ):
                sha = read_source_sha(Path("/repo"))
            self.assertEqual(sha, "08aa575ed2ff28cfb0a05c6315d1d4c416440069")
            write_case_manifest(
                evidence,
                {
                    "source_sha": sha,
                    "platform": "ios",
                    "suite": "firstboot-failure",
                    "scenario": "auth-401",
                },
            )
            payload = json.loads((evidence / "case-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["source_sha"], "08aa575ed2ff28cfb0a05c6315d1d4c416440069")
            self.assertEqual(payload["scenario"], "auth-401")

        with mock.patch(
            "run_strict_e2e.subprocess.run",
            return_value=mock.Mock(returncode=128, stdout="", stderr="not a git repo"),
        ):
            with self.assertRaises(CommandError):
                read_source_sha(Path("/repo"))


    def test_fixture_artifacts_write_independently_readable_member_manifest(self):
        from strict_e2e_server import fixture_manifest
        for fixture_set in ("a", "b"):
            with self.subTest(fixture_set=fixture_set), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                fixture = write_fixture_artifacts(root, fixture_set)
                metadata = json.loads((root / "member-manifest.json").read_text())
                target = next(album for album in fixture["albums"] if album["fixture_role"] == "target")
                self.assertEqual(metadata["target_album"]["id"], target["id"])
                self.assertEqual(metadata["fixture_sha256"], fixture_manifest(fixture_set)["fixture_sha256"])
                self.assertEqual(json.loads((root / "fixture-manifest.json").read_text()), fixture)
                with mock.patch("strict_e2e_server.fixture_manifest", return_value=dict(fixture, fixture_sha256="0" * 64)):
                    with self.assertRaisesRegex(ValueError, "frozen contract"):
                        write_fixture_artifacts(root, fixture_set)
