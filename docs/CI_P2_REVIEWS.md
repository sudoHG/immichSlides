# P2 review packages and signed records

The nightly uploads `p2-review-<shard>-<run>-<attempt>` artifacts for seven days.
Download and unzip them, open a case's `review.html`, inspect every original image
and recording, and answer Pass or Fail. Public photo references are included.
The page explains what to look for, requests the visible photo labels and controls,
and offers recording action times. No decision is preselected. Cache checks and
recording time slices use the existing [P2 sign-off contract](../scripts/strict_e2e_p2_contract.py).
Automated success remains `needs-human-review`; exporting a package never produces
a human PASS or changes the nightly's release eligibility.

## The maintainer's review

1. Inspect all items. A blank frame, bad crop, missing photo or unexpected fallback
   fails. Watch recordings at normal speed, including every listed action time.
2. Sign as `sudoHG`, select the overall conclusion, and download the JSON record.
   Overall PASS requires every answer to pass. FAIL and PARTIAL are retained as
   honest decisions, and do not qualify as passing evidence.
3. Add only that record in a pull request at the displayed path:
   `review-records/<full-tested-sha>/<suite>/<device-class>/<fixture>.json`.
   Repeat for fixture A and B. Devices are `iphone`, `ipad`, and `tv`.
   Never commit the package, images, videos, logs, or raw results.
4. Have the record PR reviewed and merged by the maintainer. The signature is the
   explicit personal attestation plus GitHub login and UTC review time; it is not
   a cryptographic identity proof. The PR's human provenance must be checked by the
   maintainer. Agents must never sign, submit, or fabricate a human review.

The record binds repository, workflow, event/ref, exact tested SHA/tree, run ID and
attempt, shard, matrix hash, full case hash and package hash. Each artifact keeps
its SHA-256, observation and decision. An automated run never fills `review-records`.
Updating a tested SHA, run/attempt, file or form invalidates the old binding.
Reviewing a new attempt requires a new human decision in a record PR.

## Validate and read by key

Use the script revision matching the package, including its HTML template. A
different template revision is rejected. Keep downloaded case directories together
under a common root, preserving `<sha>/<suite>/<device>/<fixture>`.

```bash
python3 -B scripts/ci_review_packages.py validate-record \
  --record review-records/<sha>/<suite>/<device>/<fixture>.json \
  --package '<download-root>/<sha>/<suite>/<device>/<fixture>'

python3 -B scripts/ci_review_packages.py read --sha <sha> \
  --suite p2-cache --device-class iphone --packages-dir '<download-root>'
```

Exit 0 means complete passing human evidence for this operation; exit 1 means a
valid nonpassing decision or incomplete fixture coverage; exit 2 means invalid
evidence. `read` requires both frozen fixture cases from the same run/attempt/tree,
while allowing their shards to differ. Missing, mismatched or malformed records
cannot be interpreted as PASS. The release prerequisite evaluator remains separate
work; local and PR probe packages are diagnostic evidence, never a qualifying nightly.
Validate a record before the seven-day package expiry. Committed JSON remains
readable after expiry, but rechecking its file hashes requires the original package.

## Publication boundary and reproduction

The exporter validates clean source identity, frozen public fixture identity,
original image/step hashes, the selected official XCTest method and device, and
successful private result-bundle disposal. It rejects cleanup failure. It copies
only the contract's PNGs/recording, fixed-shape steps/timing, frozen reference PNGs,
allowlisted redacted facts, package manifest and review page. Original logs,
configuration, UDIDs, absolute paths and full official exports do not upload.
The existing sensitive scanner runs on the originals, the staged package and final
export; failed scans refuse publication. A fresh destination is required. No scan
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
The bounded `ci-p2-review` PR probe collects real fixture-A cache packages on iPhone
and Apple TV to verify packaging and upload. It does not claim full P2 coverage or
human acceptance. Local device runs use the workspace's device-slot queue and
watchdog, default simulator signing and at least 80 GiB free before Xcode.
Only CI-hosted runners use the existing 30 GiB floor. Private configuration must be
absent before these fixture runs and restored afterward when temporarily parked.

Repository settings, environments, approvals, signing a review, merging its PR,
enabling release policy and creating release tags remain maintainer-gated.
