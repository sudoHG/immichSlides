# Xcode Cloud to internal TestFlight

This is the repository preparation and the maintainer's setup plan for
[#114](https://github.com/sudoHG/immichSlides/issues/114), part of
[#83](https://github.com/sudoHG/immichSlides/issues/83). It does not create or change
a cloud workflow, start a build, upload an app, or create a tag.

**Maintainer gate:** only the maintainer may perform the App Store Connect steps
below, after explicitly approving the configuration and the first upload. A
manual start consumes build numbers and can upload both apps; cancelling a run
cannot undo an upload. Leave the auto-created **Default** workflow disabled.

## Repository preparation

- `immichSlides.xcodeproj` already has one app target for iOS and tvOS, bundle ID
  `com.331works.immichSlides`, automatic signing, and the shared `immichSlides`
  scheme. Its Archive action uses Release. No project or scheme changes are needed.
- The executable `ci_scripts/ci_post_clone.sh` runs once for each cloud action,
  after cloning, while the source checkout is available. For archive actions it calls
  `scripts/check_xcode_cloud_archive.py` using isolated system Python. No Python
  packages, Homebrew installs, signing files, or upload tools are needed.
- The check refuses any `Config/env.xcconfig`, including a dangling symlink,
  and ambient Immich or debug configuration. It never opens private configuration
  or prints environment values. It requires the `immichSlides` scheme and an iOS
  or tvOS Archive action, compares the selected Xcode version/build with
  `scripts/ci-pins.json`, and requires `Package.resolved` to match the checked-out
  commit byte for byte. A failure exits 1 and stops that action; success exits 0
  and prints only the public Xcode pin and lock-file SHA-256.
- Xcode Cloud natively uses the committed Swift package resolution. Do not run a
  separate resolve, regenerate the lock file, or enable automatic package
  upgrades. The direct SDWebImageSwiftUI reference already omits `.git` (#85).
  See [Apple's dependency guidance](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud).

The pre- and post-xcodebuild scripts serve the separate
[Apple TV fixture UI workflow](XCODE_CLOUD_UI.md) and return immediately for
archive actions. Signing and TestFlight delivery belong to the release cloud
workflow. `ci_scripts/` and `scripts/` are outside all app targets;
these files do not ship in either app. Unit tests from the simulator archive
(#131) and release prerequisite/tag automation (#115) remain separate work.

## Exact workflow settings

Create one workflow named **Release to internal TestFlight**. These are desired
settings, not a claim about the current App Store Connect configuration.

| Section | Value |
|---|---|
| General | Product `immichSlides`; repository `sudoHG/immichSlides`; project `immichSlides.xcodeproj`; restrict editing enabled |
| Start Conditions, first acceptance | **Manual Start** only; Custom Branches: the maintainer-reviewed branch containing these scripts; no tags or pull requests selected |
| Start Conditions, after acceptance and release-policy approval | Replace Manual Start with **Tag Changes**, Custom Tags: enter `v` and select **Tags beginning with v** (the `v*` namespace) |
| Other start conditions | No Branch Changes, Pull Request Changes, or schedule; no file/folder filters |
| Auto-cancel Builds | Off; one release run must not cancel another release run |
| Environment: Xcode | Fixed **27.0 (27A266a)**, matching `scripts/ci-pins.json`; never “Latest” |
| Environment: macOS | Fixed **27.0**, the successful #80 cloud environment; never “Latest” |
| Environment: Clean | Enabled for both archives |
| Environment variables | No custom or shared variables, no Immich URL/key, no debug overrides, no signing credentials |
| Action 1 | **Archive**, platform **iOS**, scheme **immichSlides**, configuration **Release**, Deployment Preparation **TestFlight (Internal Testing Only)** |
| Action 2 | **Archive**, platform **tvOS**, scheme **immichSlides**, configuration **Release**, Deployment Preparation **TestFlight (Internal Testing Only)** |
| Post-Actions | **TestFlight Internal Testing**, covering both archive platforms; select only the maintainer's internal testing group |
| Other actions/post-actions | None; no simulator Test action or external distribution |
| Default workflow | Disabled throughout |

The Archive configuration comes from the scheme if the editor does not expose a
configuration picker. Apple supports multiple platform archives in one workflow
and documents the distinction between internal-only and App Store-eligible
archives in [its distribution workflow guide](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution).
These internal-only binaries cannot be submitted to the App Store. A future
App Store-eligible archive needs a separate maintainer decision.

If either fixed Xcode or macOS choice is unavailable, stop and report it; do not
silently change the pin. The successful #80 environment is recorded in
[the issue comment](https://github.com/sudoHG/immichSlides/issues/80#issuecomment-6033422159).
Only the exact Xcode version/build is enforced by the repository preflight; the
maintainer must read back the macOS selection. Cloud installation paths need not
match the GitHub runner path in the pins file. The Python/Pillow/zstd and simulator
pins are for the host/test workflows, which this archive-only workflow does not run.

## Maintainer clicks: configure, then stop before starting

All steps in this section change App Store Connect and require maintainer approval.

1. Sign in to **App Store Connect**, open **Apps**, and select **immichSlides**.
   Use the existing app record with bundle ID `com.331works.immichSlides`; do not
   create a second app or rerun onboarding. Xcode Cloud was connected during #80.
   If Apple asks for new repository access, signing authorization, agreements,
   or a paid compute plan, stop and decide separately before proceeding.
2. Open **Xcode Cloud** and **Manage Workflows**. Check that **Default** is
   inactive. Leave it inactive; do not duplicate or reactivate it.
3. Open **TestFlight**. Under **Internal Testing**, use a group containing only
   the maintainer, or click **+**, name a new group **Maintainer acceptance**, and
   click **Create**. Use **Invite Testers** to select the maintainer's existing
   App Store Connect user. Do not invite external testers. Keep automatic
   distribution off for this acceptance group.
4. Return to **Xcode Cloud → Manage Workflows**, click **+**, and name the new
   workflow **Release to internal TestFlight**. In **General**, enable
   **Restrict Editing** and confirm the product, repository, and project above.
5. In **Start Conditions**, remove the suggested Branch Changes condition and
   any other automatic conditions. Click **+ → Manual Start**; choose only the
   reviewed branch containing the repository preparation (normally `main` after
   this PR is merged). Set Auto-cancel Builds off. Do not add Tag Changes yet.
   [Apple describes Manual Start and prefix matching here](https://developer.apple.com/documentation/xcode/configuring-start-conditions).
6. In **Environment**, choose the fixed Xcode and macOS versions in the table,
   select **Clean**, and leave custom/shared environment variables empty. Use
   Xcode Cloud's managed signing; do not upload certificates or API keys.
7. In **Actions**, click **+ → Archive**. Set iOS, scheme `immichSlides`, and
   **TestFlight (Internal Testing Only)**. Add a second Archive action with
   tvOS and the same scheme and deployment preparation. Confirm both use Release.
8. In **Post-Actions**, click **+ → TestFlight Internal Testing** and select
   the maintainer's group for both platforms. If the editor separates platform
   entries, add/configure an entry for each archive. Save the workflow.
9. Reopen it and read back every row of the settings table. Record the workflow
   name, the reviewed branch's full commit SHA, and the intended marketing version.
   The current repository marketing version is `1.1.1`; verify the chosen commit
   rather than assuming that version is still current.
10. Check build-number availability before starting. In **Xcode Cloud → Settings
    → Build Number**, read **Next Build Number**. In **TestFlight**, inspect the
    existing build numbers for the intended version on both iOS and tvOS.
    Choose a next number larger than any already uploaded number for that version
    on either platform. If an edit is needed, the maintainer clicks **Edit** next
    to **Next Build Number**, enters the chosen integer, and saves. Do not reset
    the cloud counter or change `CURRENT_PROJECT_VERSION` in a script. Xcode
    Cloud assigns the distribution build number automatically; see
    [Apple's build-number instructions](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds).

**Stop here before Start Build.** The maintainer must explicitly approve the
irreversible first TestFlight upload for that commit, version, and both platforms.
Saving a manual-only workflow does not authorize starting it.

## Maintainer clicks: first manual acceptance

1. After that approval, open the saved workflow in **Xcode Cloud** and choose
   **Start Build**. Select the reviewed branch; confirm its latest commit still
   equals the SHA recorded above, then click **Start Build**. No tag is needed.
2. Open the resulting build. Confirm its commit SHA, workflow, Xcode version,
   build number, and both Archive actions. If the wrong commit was selected,
   cancel immediately, record the mistake, and check whether an upload already
   happened before deciding to retry.
3. Read each action's logs. The post-clone check must pass, and both archives
   and their TestFlight post-actions must succeed. Wait for App Store Connect
   processing; an archive alone is not a TestFlight build. If one platform fails,
   acceptance fails even if the other platform has already uploaded successfully.
4. Open **TestFlight** and check the iOS and tvOS build lists separately. Confirm
   the intended version and cloud build number are present under both platforms
   and marked internal. Resolve any export-compliance prompt truthfully; stop
   for the maintainer's decision if the answer is unclear.
5. Open the internal group and its **Builds** section. Click **+**/**Add Builds**,
   select the new processed build, enter **What to Test**, and click **Add**;
   do this for both platforms if needed. Apple's
   [internal tester guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
   says Xcode Cloud builds must be added to groups manually. Check actual group
   membership even when the workflow post-action is green.
6. On the maintainer's iPhone/iPad and Apple TV, install the new build using
   TestFlight (Apple TV may use its redemption-code flow). Confirm the correct
   version/build launches on each. This is the maintainer's device acceptance;
   do not put personal server credentials or private photo screenshots in a
   public receipt.
7. Record the full commit SHA, Xcode Cloud build link/number, each platform's
   archive and TestFlight result, internal-group availability, device installation
   result, and that no public tag was created. Keep **Default** disabled.

The issue's acceptance criterion remains **NOT_RUN / maintainer-gated** until a
manual run produces TestFlight builds for **both** platforms without a permanent
public tag. Local checks, a saved workflow, and successful archives alone cannot
complete that criterion. Do not retry or enable tag starts automatically.

## Maintainer clicks: enable tags later

Only after the manual acceptance passes and the maintainer approves the separate
release prerequisite/tag policy in #115:

1. Open **Xcode Cloud → Manage Workflows → Release to internal TestFlight → Edit**.
2. Remove Manual Start. Add **Tag Changes**, choose **Custom Tags**, enter `v`,
   and select **Tags beginning with v**. Do not enter a literal tag named `v*`,
   select Any Tag, or create a tag to test the setting. Leave file/folder filters
   empty and Auto-cancel Builds off.
3. Save, reopen, and check that only the `v*` prefix condition remains, both
   archives and internal testing remain configured, and **Default** is inactive.

Xcode Cloud watches the tag; it does not verify qualifying nightly runs or P2
reviews, enforce GitHub tag immutability, or create release tags. That belongs to
#115 and its maintainer gates. Do not manually create `v*` tags to bypass it.
App Store submission remains manual and requires separate explicit approval.

## Failures and stopping delivery

If the preflight fails, inspect only the public pin/lock state and the names of
unexpected variables; do not dump environment values or read private config.
If signing, processing, or either upload fails, record the platform and the build
link and stop before retrying. A rerun consumes another build number and may
leave the already successful platform with an extra build.

To stop future delivery, the maintainer opens **Manage Workflows**, chooses **… →
Deactivate** for this workflow, and cancels any queued/running builds separately.
Verify **Default** remains inactive. This stops future work; it does not remove
already uploaded builds or recover consumed build numbers. The maintainer can
expire an uploaded TestFlight build separately if it should no longer be installed.

## Repository verification

Run from the repository root; no simulator, Apple account, or private config is needed:

```bash
sh -n ci_scripts/ci_post_clone.sh
/usr/bin/python3 -B -m unittest discover -s scripts -p test_check_xcode_cloud_archive.py
PYTHON=/usr/bin/python3 scripts/check_all.sh
python3 scripts/git_privacy_gate.py --range origin/main..HEAD
```

The new Python file guards private-config/link rejection, value-safe logging,
unintended actions, Xcode pin mismatches, and changed/missing package resolution.
It uses synthetic files and never builds or uploads. Run the normal privacy gate
on the candidate diff as described in [CONTRIBUTING](../CONTRIBUTING.md#privacy-and-security).
Cloud script discovery, managed signing, the App Store Connect editor, uploads,
and device acceptance remain **NOT_RUN** until the approved maintainer run.
