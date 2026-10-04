"""Moved test methods; discovered through the original module and class."""

from __future__ import annotations

from access_lifecycle_contract_test_fixtures import (
    ALLOWED_SYSTEM_PAUSE_ACTIVATION,
    AccessLifecycleContractError,
    Callable,
    DEVICE_SYNTHETIC_PINS,
    FILTER_FROZEN_SHA256,
    FROZEN_FIXTURE_SHA256,
    HIDDEN_CONTROL_BAR_PLAYBACK_IDENTIFIER,
    IPAD_SCREEN,
    IPHONE_SCREEN,
    Image,
    ImageDraw,
    ImageFilter,
    LARGE_XCRESULT_NOISE_SIZE,
    LARGE_XCRESULT_SCAN_DEADLINE_SECONDS,
    MIN_STABLE_HIDDEN_WAKE_FOCUS_OBSERVATIONS,
    NEW_STABLE_MARK_CONFIRM_WINDOW,
    NEW_STABLE_MARK_MIN_LUMA,
    NEW_STABLE_MARK_POLL_INTERVAL,
    NON_PLAYBACK_LAYER_PREFIXES,
    PLAYBACK_LAYER_PREFIX,
    Path,
    SCRIPT_DIR,
    SYNTHETIC_PIN,
    TV_SCREEN,
    _FALSE_GZIP_UNIT,
    _MarkSample,
    _STAND_IN_FRAMES,
    _checkerboard_mix,
    _compose_side_partner,
    _compose_smart_fill,
    _cover,
    _device_payload,
    _device_payload_ready_for_background,
    _dissolve_screen,
    _fixture_data,
    _fixture_image,
    _fixture_png,
    _gzip_content_frame,
    _large_xcresult_noise,
    _png_bytes,
    _pool_end_single_photo_display,
    _side_by_side,
    _side_by_side_screen,
    _side_by_side_transition_display,
    _single_on_own_blur,
    _single_photo_swap_display,
    _stacked_screen,
    _stand_in_png,
    _system_pause_payload,
    _unchanged_fullbleed_display,
    _valid_payload,
    _valid_settings_return_wake,
    _with_bottom_controls,
    _zstd_cli_frame,
    _zstd_content_frame,
    _zstd_frame_size,
    _zstd_skippable_frame,
    assert_appletv_double_layout_visible,
    assert_display_before_letterbox,
    assert_display_before_pool_burn,
    assert_display_strategy_visible,
    assert_returned_to_slideshow,
    assert_settings_open,
    assert_settings_return_wake,
    assert_system_pause_activation,
    assert_system_pause_identity_timing,
    assert_unshown_display_partners,
    capture_identity,
    classify_display_regions,
    classify_screenshot,
    compressed_byte_coincidence,
    confirm_wait,
    evaluate_access_lifecycle_evidence,
    gzip,
    inspect_display_strategy,
    io,
    is_confirmed_new_stable_mark,
    is_slideshow_layer,
    json,
    logical_content_bytes,
    mock,
    poll_wait,
    scan_sensitive_evidence,
    subprocess,
    sys,
    tempfile,
    time,
    unittest,
    wait_for_new_stable_mark,
)

class SensitiveScanTestsCases:
    def test_pin_in_filename_fails_without_echoing_pin(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / f"gate-{SYNTHETIC_PIN}.png").write_bytes(b"not-an-image")
            with self.assertRaises(AccessLifecycleContractError) as raised:
                scan_sensitive_evidence(root, [SYNTHETIC_PIN])
            self.assertIn("PIN", str(raised.exception))
            self.assertNotIn(SYNTHETIC_PIN, str(raised.exception))


    def test_pin_in_command_log_or_attachment_fails(self) -> None:
        cases = {
            "commands.txt": f"xcodebuild test -only-testing PIN={SYNTHETIC_PIN}\n",
            "service.log": f"entered pin {SYNTHETIC_PIN}\n",
            "notes.json": json.dumps({"attachment": SYNTHETIC_PIN}),
        }
        for name, content in cases.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    (root / name).write_text(content, encoding="utf-8")
                    with self.assertRaises(AccessLifecycleContractError) as raised:
                        scan_sensitive_evidence(root, [SYNTHETIC_PIN])
                    self.assertIn("PIN", str(raised.exception))
                    self.assertNotIn(SYNTHETIC_PIN, str(raised.exception))


    def test_task_derived_data_is_not_final_persistent_evidence(self) -> None:
        # DerivedData remained under the evidence root while device evidence was evaluated.
        pin = DEVICE_SYNTHETIC_PINS[0]
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            derived = root / "DerivedData" / "Build" / "Intermediates.noindex"
            derived.mkdir(parents=True)
            (derived / f"pin-{pin}.log").write_text(f"PIN={pin}\n", encoding="utf-8")
            (root / "xcodebuild-command.txt").write_text(
                "xcodebuild -derivedDataPath DerivedData test\n",
                encoding="utf-8",
            )
            result = scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
            self.assertEqual(result["result"], "PASS")
            self.assertEqual(result["matched_files"], [])


    def test_persistent_pin_leak_still_fails_when_derived_data_also_leaks(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        cases = {
            "xcodebuild-command.txt": f"xcodebuild test PIN={pin}\n",
            "xcodebuild.log": f"entered pin {pin}\n",
            "service.log": f"pin {pin}\n",
            "notes.json": json.dumps({"attachment": pin}),
            f"gate-{pin}.png": "not-an-image",
        }
        for name, content in cases.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as raw:
                    root = Path(raw)
                    derived = root / "DerivedData" / "Logs"
                    derived.mkdir(parents=True)
                    (derived / "build.log").write_text(f"PIN={pin}\n", encoding="utf-8")
                    (root / name).write_text(content, encoding="utf-8")
                    with self.assertRaises(AccessLifecycleContractError) as raised:
                        scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
                    self.assertIn("PIN", str(raised.exception))
                    for value in DEVICE_SYNTHETIC_PINS:
                        self.assertNotIn(value, str(raised.exception))


    def test_xcresult_pin_still_fails_when_derived_data_present(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        logical = f"entered pin {pin}\n".encode("utf-8")
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            derived = root / "DerivedData" / "Build"
            derived.mkdir(parents=True)
            (derived / f"pin-{pin}.bin").write_bytes(logical)
            payload = root / "access-lifecycle-tvos.xcresult" / "Data" / "payload.bin"
            payload.parent.mkdir(parents=True)
            payload.write_bytes(_zstd_content_frame(logical))
            with self.assertRaises(AccessLifecycleContractError) as raised:
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
            self.assertIn("PIN", str(raised.exception))
            for value in DEVICE_SYNTHETIC_PINS:
                self.assertNotIn(value, str(raised.exception))


    def test_redacted_evidence_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "commands.txt").write_text(
                "python3 scripts/test_access_lifecycle_contract.py -v\n",
                encoding="utf-8",
            )
            (root / "pin-gate.png").write_bytes(b"redacted")
            (root / "notes.json").write_text(
                json.dumps({"pin": "<redacted-pin>"}),
                encoding="utf-8",
            )
            result = scan_sensitive_evidence(root, [SYNTHETIC_PIN])
            self.assertEqual(result["result"], "PASS")
            self.assertEqual(result["matched_files"], [])


    def test_skippable_payload_with_pin_fails(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        logical = b"<?xml version=\"1.0\"?><plist><string>no-pin</string></plist>"
        blob = _zstd_skippable_frame(pin.encode("utf-8")) + _zstd_content_frame(logical)
        self.assertIn(pin.encode("utf-8"), blob)
        self.assertNotIn(pin.encode("utf-8"), logical)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(AccessLifecycleContractError):
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)


    def test_undecodable_zstd_with_plaintext_pin_fails(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        blob = b"\x28\xb5\x2f\xfd" + pin.encode("utf-8") + b"not-a-frame"
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(AccessLifecycleContractError):
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)


    def test_genuinely_compressed_pattern_with_clean_logical_content_passes(self) -> None:
        blob, logical, needle = compressed_byte_coincidence()
        self.assertIn(needle.encode(), blob)
        self.assertNotIn(needle.encode(), logical)
        self.assertEqual(subprocess.run(
            ["zstd", "-q", "-d", "-c"], input=blob, capture_output=True, check=True
        ).stdout, logical)
        self.assertEqual(_zstd_cli_frame(blob, 0), (logical, len(blob)))
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            result = scan_sensitive_evidence(root, [needle])
            self.assertEqual(result["result"], "PASS")
            self.assertEqual(result["matched_files"], [])


    def test_cli_only_zstd_plaintext_tail_with_pin_fails(self) -> None:
        blob = _zstd_content_frame(b"safe") + DEVICE_SYNTHETIC_PINS[0].encode()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
                "access_lifecycle_contract._load_libzstd", return_value=None
            ):
                with self.assertRaises(AccessLifecycleContractError):
                    scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)


    def test_zstd_cli_accounts_for_header_fields_and_raw_rle_blocks(self) -> None:
        for single_segment in (False, True):
            for size_flag in range(4):
                for dictionary_flag, dictionary_bytes in enumerate((0, 1, 2, 4)):
                    with self.subTest(single=single_segment, size=size_flag, dictionary=dictionary_flag):
                        size = 256 if size_flag == 1 else 6
                        descriptor = (size_flag << 6) | (int(single_segment) << 5) | dictionary_flag
                        content_bytes = (int(single_segment), 2, 4, 8)[size_flag]
                        encoded_size = size - 256 if size_flag == 1 else size
                        header = b"\x28\xb5\x2f\xfd" + bytes([descriptor])
                        header += b"" if single_segment else b"\x00"
                        header += bytes(dictionary_bytes)
                        if content_bytes:
                            header += encoded_size.to_bytes(content_bytes, "little")
                        for block_type in (0, 1):
                            logical = b"A" * size
                            block = ((size << 3) | (block_type << 1) | 1).to_bytes(3, "little")
                            block += b"A" if block_type == 1 else logical
                            frame = header + block
                            data = b"prefix" + frame + b"cleartext tail"
                            self.assertEqual(_zstd_frame_size(data, 6), len(frame))
                            self.assertEqual(_zstd_cli_frame(data, 6), (logical, len(frame)))


    def test_zstd_cli_preserves_concatenated_frames_metadata_and_plaintext(self) -> None:
        blob, logical, _ = compressed_byte_coincidence()
        first = _zstd_content_frame(b"first")
        second = _zstd_content_frame(b"second" * 100000)
        data = b"prefix" + first + _zstd_skippable_frame(b"metadata") + second + blob + b"tail"
        with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
            "access_lifecycle_contract._load_libzstd", return_value=None
        ):
            self.assertEqual(_zstd_cli_frame(data, 6), (b"first", len(first)))
            self.assertEqual(logical_content_bytes(data), b"prefixfirstmetadata" + b"second" * 100000 + logical + b"tail")


    def test_zstd_truncation_and_missing_decoder_preserve_raw_bytes(self) -> None:
        frame = _zstd_content_frame(b"safe")
        for truncated_size in range(1, len(frame)):
            with self.subTest(truncated_size=truncated_size):
                truncated = frame[:truncated_size]
                self.assertIsNone(_zstd_frame_size(truncated, 0))
                self.assertEqual(logical_content_bytes(truncated), truncated)
        data = frame + DEVICE_SYNTHETIC_PINS[0].encode()
        with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
            "access_lifecycle_contract._load_libzstd", return_value=None
        ), mock.patch("shutil.which", return_value=None):
            self.assertEqual(logical_content_bytes(data), data)


    def test_all_skippable_magic_variants_preserve_payload_and_truncated_frames(self) -> None:
        payload = DEVICE_SYNTHETIC_PINS[0].encode()
        for magic in range(0x184D2A50, 0x184D2A60):
            with self.subTest(magic=magic):
                frame = magic.to_bytes(4, "little") + len(payload).to_bytes(4, "little") + payload
                self.assertEqual(logical_content_bytes(frame + b"tail"), payload + b"tail")
                truncated = magic.to_bytes(4, "little") + (len(payload) + 1).to_bytes(4, "little") + payload
                self.assertEqual(logical_content_bytes(truncated), truncated)


    def test_zstd_reserved_headers_and_failed_checksum_are_scanned_raw(self) -> None:
        frame = _zstd_content_frame(b"safe")
        malformed = [
            frame[:4] + bytes([frame[4] | 8]) + frame[5:],
            frame[:-1] + bytes([frame[-1] ^ 1]),
            b"\x28\xb5\x2f\xfd\x20\x00\x07\x00\x00",
        ]
        with mock.patch("access_lifecycle_contract._zstd_py314", return_value=None), mock.patch(
            "access_lifecycle_contract._load_libzstd", return_value=None
        ):
            for blob in malformed:
                with self.subTest(blob=blob):
                    data = blob + DEVICE_SYNTHETIC_PINS[0].encode()
                    self.assertEqual(logical_content_bytes(data), data)


    def test_decompressed_logical_content_with_pin_fails_without_echoing_pin(self) -> None:
        pin = DEVICE_SYNTHETIC_PINS[0]
        logical = f"entered pin {pin}\n".encode("utf-8")
        blob = _zstd_content_frame(logical)
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "xcresult-data.bin").write_bytes(blob)
            with self.assertRaises(AccessLifecycleContractError) as raised:
                scan_sensitive_evidence(root, DEVICE_SYNTHETIC_PINS)
            self.assertIn("PIN", str(raised.exception))
            for value in DEVICE_SYNTHETIC_PINS:
                self.assertNotIn(value, str(raised.exception))


    def test_large_xcresult_like_blob_scan_is_bounded(self) -> None:
        # A failed device assertion still triggered a sensitive scan that repeatedly searched a large xcresult.
        pin = DEVICE_SYNTHETIC_PINS[0]
        pin_bytes = pin.encode("utf-8")
        noise = _large_xcresult_noise()
        self.assertGreaterEqual(len(noise), LARGE_XCRESULT_NOISE_SIZE)
        self.assertNotIn(pin_bytes, noise)
        compressed_ok, logical_ok, coincidence = compressed_byte_coincidence()
        pass_blob = noise + _zstd_skippable_frame(b"safe metadata") + compressed_ok
        self.assertIn(coincidence.encode(), pass_blob)
        self.assertNotIn(coincidence.encode(), logical_ok)
        self.assertNotIn(pin_bytes, logical_ok)
        logical_bad = f"entered pin {pin}\n".encode("utf-8")
        fail_blob = noise + _gzip_content_frame(logical_bad)

        def scan_blob(blob: bytes, values: list[str] = DEVICE_SYNTHETIC_PINS) -> tuple[float, object]:
            with tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                payload = root / "Test.xcresult" / "Data" / "payload.bin"
                payload.parent.mkdir(parents=True)
                payload.write_bytes(blob)
                started = time.perf_counter()
                try:
                    result = scan_sensitive_evidence(root, values)
                except AccessLifecycleContractError as error:
                    elapsed = time.perf_counter() - started
                    return elapsed, error
                elapsed = time.perf_counter() - started
                return elapsed, result

        elapsed, result = scan_blob(pass_blob, [*DEVICE_SYNTHETIC_PINS, coincidence])
        self.assertLess(elapsed, LARGE_XCRESULT_SCAN_DEADLINE_SECONDS)
        self.assertEqual(result["result"], "PASS")
        self.assertEqual(result["matched_files"], [])

        elapsed, error = scan_blob(fail_blob)
        self.assertLess(elapsed, LARGE_XCRESULT_SCAN_DEADLINE_SECONDS)
        self.assertIsInstance(error, AccessLifecycleContractError)
        self.assertIn("PIN", str(error))
        for value in DEVICE_SYNTHETIC_PINS:
            self.assertNotIn(value, str(error))
