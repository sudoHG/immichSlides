# Xcode Cloud to internal TestFlight

This guide covers archive-only Release builds and the maintainer's upload gate.
It does not claim that the external App Store Connect settings have been applied.
CI results do not authorize uploads, release tags or App Store submission.

## Repository preparation

The shared `immichSlides` scheme archives the multiplatform App in Release.
`ci_scripts/ci_post_clone.sh` invokes `scripts/check_xcode_cloud_archive.py`
for Archive actions using isolated system Python. There are no Cloud UI test
hooks. Existing external workflows with Test actions need a separate maintainer
audit; this repository does not configure them.

Preflight rejects local configuration files/symlinks and ambient server/debug
inputs without reading private values. It requires the App scheme, an iOS/tvOS
Archive action, the exact Xcode version/build in `scripts/ci-pins.json` and
byte-identical committed `Package.resolved`.
Failure stops the action; success prints only public pin/lock information.
Do not regenerate package resolution or upload signing credentials.

These scripts are outside App targets. Simulator archive/unit CI is separate:
[Build archives](CI_BUILD_ARCHIVE.md), [Offline units](CI_UNIT_TESTS.md).

## Desired workflow settings

Only the maintainer configures App Store Connect after explicit authorization.
Keep the auto-created Default workflow disabled.

| Setting | Value |
| --- | --- |
| Name / repository / project | Release to internal TestFlight / sudoHG/immichSlides / immichSlides.xcodeproj |
| Editing | Restricted |
| Initial starts | Manual only, reviewed branch; no schedule, PR or branch-change triggers |
| Auto-cancel | Off |
| Xcode | Fixed 27.0 (27A266a), matching repository pins |
| macOS | Fixed 27.0; maintainer must confirm availability |
| Clean | Enabled for both archives |
| Custom/shared environment | Empty; no server, key, debug or signing inputs |
| iOS action | Archive, immichSlides, Release, TestFlight (Internal Testing Only) |
| tvOS action | Archive, immichSlides, Release, TestFlight (Internal Testing Only) |
| Post-action | TestFlight Internal Testing for the maintainer's internal group |
| Other actions | None; no Test action or external distribution |

If a fixed environment is unavailable, stop for a maintainer decision.
Cloud paths need not equal GitHub's Xcode path; preflight enforces version/build.
Simulator/Python package pins do not apply to this archive-only workflow.
Internal-only binaries cannot be submitted to the App Store.

## Configure and stop before upload

In the existing App Store Connect app record, inspect Xcode Cloud workflows and
keep Default inactive. Create/edit only the approved archive workflow and read
back every setting above. Do not grant new repository/signing access, accept
agreements or change paid plans without a separate decision.

Record the reviewed branch's full SHA and read its actual marketing version.
Inspect TestFlight build numbers for both platforms and Xcode Cloud's Next Build
Number; choose a number above all uploaded builds for that version.
Do not reset counters or change project build numbers through scripts.
Saving a workflow does not authorize starting it.

**Stop before Start Build.** The maintainer must explicitly approve the first
upload for that commit, version and both platforms. Starting consumes build
numbers and may upload both apps; cancellation cannot undo an upload.

## First manual acceptance

After approval, start the reviewed SHA and read back workflow, version, build
number and Xcode pin. Both archives and TestFlight post-actions must succeed.
Wait for App Store Connect processing and confirm both platform builds are
internal and available to the intended internal group; an archive alone is
insufficient. Resolve export-compliance questions through the maintainer.

Install the chosen version/build through TestFlight on the maintainer's
iPhone/iPad and Apple TV. Record the SHA, Cloud build link/number, both archive
and upload results, group availability and device acceptance without private
credentials/photos. Device acceptance remains `NOT_RUN` until performed.
Do not retry automatically after partial upload.

## Later tag starts and stopping delivery

Tag-triggered starts require separate maintainer approval after manual acceptance.
If approved, use Custom Tags beginning with `v`, remove other start conditions,
and read back the workflow. Do not create a tag merely to test it.
Xcode Cloud does not enforce GitHub test results or tag immutability.
Run the [full smoke scope](CI_NIGHTLY.md) before release and report its results;
smoke never blocks merges. App Store submission needs its own explicit approval.

To stop future delivery, the maintainer deactivates the workflow and separately
cancels queued/running builds, confirming Default stays disabled.
This does not remove uploaded builds or recover build numbers.

## Repository verification

```bash
sh -n ci_scripts/ci_post_clone.sh
python3 -B -m unittest discover -s scripts -p test_check_xcode_cloud_archive.py
scripts/check_all.sh
python3 -B scripts/git_privacy_gate.py --range origin/main..HEAD
```

These checks use synthetic files and never upload.
External script discovery, managed signing, processing and device installation
require the approved maintainer run.
