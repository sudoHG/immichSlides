## Summary

<!-- What problem does this solve, and how? One problem per PR. -->

Linked issue: <!-- Closes #123 -->

## What changed

-

## What deliberately did not change

-

## Verification

Run on the final commit. Paste the result, and report failures with their output.

| Command | Result |
|---|---|
| `scripts/check_all.sh` | |
| Unit tests, iOS (`scripts/check_all.sh --with-unit-tests --ios-destination '<dest>' --tvos-destination '<dest>' --output-dir '<outside-repo>'` or the full `run_offline_unit_tests.py` command in [CONTRIBUTING.md](https://github.com/sudoHG/immichSlides/blob/main/CONTRIBUTING.md#setup)) | |
| Unit tests, tvOS (same `check_all.sh --with-unit-tests` command, or `run_offline_unit_tests.py --platform tvos` with `--destination`, `--derived-data-path`, and `--result-bundle-path`) | |
| Other (UI / E2E suites, manual checks) | |

Failures that already existed before this change:

## UI changes (skip if none)

- [ ] Before and after screenshots of the changed screen, same device and settings (attached below)
- [ ] Checked iPhone and iPad, light and dark mode, large Dynamic Type
- [ ] tvOS: default focus, remote navigation, Select and Back, focus scaling
- [ ] Screenshots contain no private photos, faces, server addresses or credentials

| Before | After |
|---|---|
| | |

## Localization (skip if no strings changed)

- [ ] Every new or changed string has all locales (source `en`, plus `zh-Hans`, `zh-Hant-HK`, `zh-Hant-TW`, `es`, `ja`)
- [ ] `python3 scripts/validate_localization_catalog.py` prints `status=PASS`

## Checklist

- [ ] Tests written or updated first for logic changes ([docs/TESTING.md](https://github.com/sudoHG/immichSlides/blob/main/docs/TESTING.md))
- [ ] iOS and tvOS both build; platform code is in the platform directories
- [ ] No new third-party dependency (or it was agreed in the linked issue)
- [ ] No secrets, `env.xcconfig`, `.xcresult` bundles or private data committed
- [ ] Docs updated if behavior, commands, layout or privacy changed
- [ ] AI-assisted: I read the diff and take responsibility for it
- [ ] I agree to the [Contribution license](https://github.com/sudoHG/immichSlides/blob/main/CONTRIBUTING.md#contribution-license)

## Not verified

<!-- Anything you did not run or check, and why. -->

## Risks

<!-- What could break, and what to watch for. -->
