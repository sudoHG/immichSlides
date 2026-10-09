# P2 review packages and signed records

The nightly uploads `p2-review-<shard>-<run>-<attempt>` artifacts for seven days.
Download and unzip them, open a case's `review.html`, inspect every original image
and recording, and answer Pass, Fail, or Not reviewed / Partial. Public photo references are included.
The page explains what to look for, requests the visible photo labels and controls,
and offers recording action times. No decision is preselected. Cache checks and
recording time slices use the existing [P2 sign-off contract](../scripts/strict_e2e_p2_contract.py).
Automated success remains `needs-human-review`; exporting a package never produces
a human PASS or changes the nightly's release eligibility.

## The maintainer's review

1. Inspect all items. A blank frame, bad crop, missing photo or unexpected fallback
   fails. Watch recordings at normal speed, including every listed action time.
2. Sign as `sudoHG`, select the overall conclusion, and download the JSON record.
   Overall PASS requires every item, check and time slice to pass. FAIL dominates
   PARTIAL; the overall conclusion must match these decisions. FAIL and PARTIAL are retained as
   honest decisions, and do not qualify as passing evidence.
3. Add only that record in a pull request at the displayed path:
   `review-records/<full-tested-sha>/<suite>/<device-class>/<fixture>.json`.
   Repeat for fixture A and B. Devices are `iphone`, `ipad`, and `tv`.
   Never commit the package, images, videos, logs, or raw results.
4. Have the record PR reviewed and merged by the maintainer. The signature is the
   explicit attestation that the decisions and observations are their own, plus
   GitHub login and UTC review time after the package's last step; it is not
   a cryptographic identity proof. The PR's human provenance must be checked by the
   maintainer. Agents must never sign, submit, or fabricate a human review.

The record binds repository, workflow, event/ref, exact tested SHA/tree, run ID and
attempt, shard, matrix hash, full case hash and package hash. Each artifact keeps
its SHA-256, observation and decision. Version 2 records embed the complete package
manifest, including machine-recognized photo labels and the last step time.
Human labels are recorded separately: a disagreement can be FAIL or PARTIAL;
PASS still requires agreement with the machine-recognized returned photo.
An automated run never fills `review-records`. Updating a tested SHA, run/attempt,
file or retained manifest invalidates the old binding.
Reviewing a new attempt requires a new human decision in a record PR.

Each FAIL or PARTIAL item/time slice requires a short personal note; a nonpassing
cache check also requires an item note. Partial means the item is incomplete or
not reviewed, and can never contribute to overall PASS. Blank optional PASS notes
are saved honestly as `No note entered; reviewer selected PASS.` The form never
invents claims that an image was visually reviewed or a recording was watched.
Record-only changes are classified `app_unaffected`, so pull requests that only
change review records skip the iOS/tvOS build and unit jobs while host checks
still run under the [trusted gate classification contract](CI_PUBLISHER.md).

## Validate and read by key

When media is available, use the script revision matching the package, including
its HTML template; a different template revision is rejected. Keep case directories together
under a common root, preserving `<sha>/<suite>/<device>/<fixture>`.

```bash
python3 -B scripts/ci_review_packages.py validate-record \
  --record review-records/<sha>/<suite>/<device>/<fixture>.json \
  --package '<download-root>/<sha>/<suite>/<device>/<fixture>'

python3 -B scripts/ci_review_packages.py read --sha <sha> \
  --suite p2-cache --device-class iphone --packages-dir '<download-root>' \
  --bindings '<retained-nightly-aggregate>/nightly.json'

# After media expiry, validate the embedded manifest and signed decisions.
python3 -B scripts/ci_review_packages.py validate-record \
  --record review-records/<sha>/<suite>/<device>/<fixture>.json
python3 -B scripts/ci_review_packages.py read --sha <sha> \
  --suite p2-cache --device-class iphone \
  --bindings '<retained-nightly-aggregate>/nightly.json'
```

`validate-record` checks one record's structure, signature and verdict consistency;
it does not establish nightly eligibility. For `read`, exit 0 requires complete
passing human records, matching retained producer hashes, and a qualifying
`schedule`/`workflow_dispatch` from `.github/workflows/ci-nightly.yml` on
`refs/heads/main`. Other sources are explicitly `NON_QUALIFYING` and never exit 0.
Exit 1 means a valid nonpassing decision, incomplete fixture coverage, missing
producer bindings or non-qualifying source; exit 2 means invalid evidence.
`read` requires both frozen fixture cases from the same run/attempt/tree,
while allowing their shards to differ. Any known FAIL remains FAIL even when the
other fixture is missing; incomplete or partially reviewed evidence stays PARTIAL.
Missing, mismatched or malformed records
cannot be interpreted as PASS. The release prerequisite evaluator remains separate
work; local and PR probe packages are diagnostic evidence, never a qualifying nightly.
Committed JSON remains structurally readable after expiry without media. The
reader reports `package-expired` distinctly, rather than treating missing media as
invalid evidence. If media is present, its bytes and page are still revalidated.
Retain `p2-review-bindings.json` from the compact shard records or the aggregate's
`review_packages`/rollup metadata before their artifact expiry for long-term hash
comparison. Missing bindings are reported as `binding-unavailable`, never PASS.
These metadata files contain identities and hashes, not media. An embedded manifest
with changed hashes is rejected against the retained producer binding. The
maintainer must check artifact and review PR provenance; hashes are not signatures.

## Publication boundary and reproduction

The exporter validates clean source identity, frozen public fixture identity,
original image/step hashes, the selected official XCTest method and device, and
successful private result-bundle disposal. It rejects cleanup failure. It copies
only the contract's PNGs/recording, fixed-shape steps/timing, frozen reference PNGs,
allowlisted redacted facts, package manifest and review page. Original logs,
configuration, UDIDs, absolute paths and full official exports do not upload.
The existing sensitive scanner runs on the originals, the staged package and final
export; scan reports are written outside the scanned directories and do not mutate
or enter the media package. Failed scans refuse publication. A fresh destination is required. No scan
or visual threshold is weakened.

```bash
python3 -B scripts/ci_review_packages.py export-shard \
  --input-dir '<outside-repo>/nightly-strict' --output-dir '<fresh-outside-repo>/packages'

python3 -B scripts/ci_review_packages.py export-case \
  --evidence-dir '<outside-repo>/strict-p2-cache' --output-dir '<fresh-outside-repo>/package' \
  --suite p2-cache --device-class iphone --fixture a
```

The shard index lists available cases and fixed reasons for unavailable ones;
failed automated cases are never replaced with misleading review packages.
Package validation failure makes the export step fail and prevents its upload.
Other shard packages and compact nightly failures remain independent.
Before compact records upload, the exporter writes case identity, context, case hash
and package hash into `records/p2-review-bindings.json`. The aggregate validates each
binding against its completed P2 observation and retains them in `review_packages`
and its rollup entry. Missing or mismatched bindings fail aggregation.
The bounded `ci-p2-review` PR probe collects a real fixture-A cache package on iPhone
to verify packaging and upload. The nightly retains its full device matrix.
The probe does not claim full P2 coverage or human acceptance.
Its cold build uses the nightly's 1200-second budget; the actual
test keeps its 300-second budget and the job is bounded to 45 minutes.
Local device runs use the workspace's device-slot queue and
watchdog, default simulator signing and at least 80 GiB free before Xcode.
Only CI-hosted runners use the existing 30 GiB floor. Private configuration must be
absent before these fixture runs and restored afterward when temporarily parked.

Repository settings, environments, approvals, signing a review, merging its PR,
enabling release policy and creating release tags remain maintainer-gated.
