#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
from pathlib import Path


FORBIDDEN_PATTERN = re.compile(
    r"safeFullDisplay|fitBlurred|fit-blurred-background|fitWithBlurredBackground|"
    r"scaledToFit|\.blur\(|Material|regularMaterial|letterbox|pillarbox|"
    r"background fit|canvasFill|blurred-primary|background fill"
)

RENDERER_FILES = {
    "immichSlides/Shared/Component/SmartFillSceneView.swift",
    "immichSlides/Shared/Component/SlideItemView.swift",
}


def main():
    parser = argparse.ArgumentParser(description="Fail when a diff adds a forbidden visual fallback or changes the SmartFill renderer")
    parser.add_argument("--repo-root", default=".", help="Repository root")
    parser.add_argument("--base-ref", default="origin/main", help="Base ref to diff against")
    parser.add_argument("--report", help="Optional report output path")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    report = build_report(repo_root, args.base_ref)
    text = format_report(report)
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(text, encoding="utf-8")
    print(text, end="")
    return 1 if report["failed"] else 0


def build_report(repo_root, base_ref):
    changed_paths = set(git_lines(repo_root, ["diff", "--name-only", base_ref, "--"]))
    changed_paths.update(git_lines(repo_root, ["ls-files", "--others", "--exclude-standard"]))

    renderer_diff_paths = sorted(path for path in changed_paths if path in RENDERER_FILES)
    baseline_hits = scan_current_production_hits(repo_root)
    allowed_hits = scan_allowed_hits(repo_root)
    diff_hits = scan_diff_added_line_hits(repo_root, base_ref, changed_paths)
    new_renderer_hits = [
        hit for hit in diff_hits
        if hit["path"] in RENDERER_FILES or ("SmartFill" in Path(hit["path"]).name and "/Component/" in hit["path"])
    ]
    failed = bool(diff_hits or new_renderer_hits or renderer_diff_paths)
    return {
        "failed": failed,
        "renderer_diff_paths": renderer_diff_paths,
        "baseline_hits": baseline_hits,
        "allowed_hits": allowed_hits,
        "diff_hits": diff_hits,
        "new_renderer_hits": new_renderer_hits,
    }


def scan_current_production_hits(repo_root):
    hits = []
    for path in list_files(repo_root):
        if not is_production_swift(path):
            continue
        hits.extend(scan_file_for_hits(repo_root, path, category="baselineAllowedHit"))
    return hits


def scan_allowed_hits(repo_root):
    hits = []
    for path in list_files(repo_root):
        if is_allowed_hit_path(path):
            hits.extend(scan_file_for_hits(repo_root, path, category="allowedHit"))
    return hits


def scan_diff_added_line_hits(repo_root, base_ref, changed_paths):
    hits = []
    untracked = set(git_lines(repo_root, ["ls-files", "--others", "--exclude-standard"]))
    for path in sorted(changed_paths):
        if not is_production_path(path):
            continue
        if path in untracked:
            hits.extend(scan_file_for_hits(repo_root, path, category="diffProductionHit"))
            continue
        diff = git_text(repo_root, ["diff", "--unified=0", base_ref, "--", path])
        current_line = None
        for line in diff.splitlines():
            if line.startswith("@@"):
                match = re.search(r"\+(\d+)", line)
                current_line = int(match.group(1)) if match else None
                continue
            if line.startswith("+") and not line.startswith("+++"):
                added_text = line[1:]
                if FORBIDDEN_PATTERN.search(added_text):
                    hits.append({
                        "category": "diffProductionHit",
                        "path": path,
                        "line": current_line or 0,
                        "text": added_text.strip(),
                    })
                if current_line is not None:
                    current_line += 1
            elif current_line is not None and not line.startswith(("-", "\\")):
                current_line += 1
    return hits


def scan_file_for_hits(repo_root, path, category):
    full_path = repo_root / path
    if not full_path.is_file():
        return []
    hits = []
    try:
        lines = full_path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        return []
    for index, line in enumerate(lines, start=1):
        if FORBIDDEN_PATTERN.search(line):
            hits.append({
                "category": category,
                "path": path,
                "line": index,
                "text": line.strip(),
            })
    return hits


def list_files(repo_root):
    paths = set(git_lines(repo_root, ["ls-files"]))
    paths.update(git_lines(repo_root, ["ls-files", "--others", "--exclude-standard"]))
    return sorted(paths)


def is_production_swift(path):
    return path.startswith("immichSlides/") and path.endswith(".swift")


def is_production_path(path):
    return is_production_swift(path)


def is_allowed_hit_path(path):
    return (
        path == "docs/ARCHITECTURE.md"
        or path.startswith("TestSupport/SmartFillVisualFallbackFixtures/")
        or "/reviewer_packet/" in path
    )


def format_report(report):
    status = "FAIL" if report["failed"] else "PASS"
    renderer_empty = "PASS" if not report["renderer_diff_paths"] else "FAIL"
    lines = [
        f"guardrail_check_status={status}",
        f"smartfill_renderer_diff_empty={renderer_empty}",
        f"slide_item_diff_empty={renderer_empty if any(path.endswith('SlideItemView.swift') for path in report['renderer_diff_paths']) else 'PASS'}",
        f"forbidden_visual_diff_production_hits={len(report['diff_hits'])}",
        f"forbidden_visual_new_smartfill_renderer_hits={len(report['new_renderer_hits'])}",
        f"forbidden_visual_baseline_allowed_hits={len(report['baseline_hits'])}",
        f"forbidden_visual_allowed_hits={len(report['allowed_hits'])}",
    ]
    lines.extend(format_hits("renderer_diff", [{"path": path, "line": 0, "text": "renderer file changed"} for path in report["renderer_diff_paths"]]))
    lines.extend(format_hits("diffProductionHit", report["diff_hits"]))
    lines.extend(format_hits("baselineAllowedHit", report["baseline_hits"]))
    lines.extend(format_hits("allowedHit", report["allowed_hits"]))
    return "\n".join(lines) + "\n"


def format_hits(label, hits):
    return [
        f"{label}={hit['path']}:{hit['line']}:{hit['text']}"
        for hit in hits
    ]


def git_lines(repo_root, args):
    text = git_text(repo_root, args)
    return [line for line in text.splitlines() if line]


def git_text(repo_root, args):
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout


if __name__ == "__main__":
    sys.exit(main())
