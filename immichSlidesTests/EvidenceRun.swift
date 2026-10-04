import Foundation

/// Evidence tooling (benchmarks, live probes) runs only when the Evidence test plans set `IMMICHSLIDES_EVIDENCE=1`.
/// Test plan filters do not apply to this unit test target, so an environment switch keeps it out of default runs.
let isEvidenceRun = ProcessInfo.processInfo.environment["IMMICHSLIDES_EVIDENCE"] == "1"
