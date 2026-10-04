#!/bin/sh
set -eu

repository_root=$(git rev-parse --show-toplevel)
git_common_directory=$(git -C "$repository_root" rev-parse --git-common-dir)
case "$git_common_directory" in
    /*) ;;
    *) git_common_directory="$repository_root/$git_common_directory" ;;
esac
git_common_directory=$(CDPATH= cd -- "$git_common_directory" && pwd -P)

install_root="$git_common_directory/immichSlides-privacy-gate"
versions_directory="$install_root/versions"
legacy_hooks_directory="$install_root/hooks"
worktree_list_file=
worktree_value_file=
candidate_directory=

cleanup() {
    if [ -n "$candidate_directory" ] && [ -d "$candidate_directory" ]; then
        rm -rf -- "$candidate_directory"
    fi
    if [ -n "$worktree_list_file" ]; then
        rm -f -- "$worktree_list_file"
    fi
    if [ -n "$worktree_value_file" ]; then
        rm -f -- "$worktree_value_file"
    fi
}
trap cleanup EXIT HUP INT TERM

umask 077
mkdir -p "$versions_directory"
chmod 700 "$install_root" "$versions_directory"
worktree_list_file=$(mktemp "$install_root/worktrees.XXXXXX")
worktree_value_file=$(mktemp "$install_root/worktree-value.XXXXXX")
git -C "$repository_root" worktree list --porcelain |
    sed -n 's/^worktree //p' >"$worktree_list_file"
worktree_config_enabled=$(
    git -C "$repository_root" config \
        --type=bool \
        --get extensions.worktreeConfig || true
)

while IFS= read -r worktree_path; do
    [ -n "$worktree_path" ] || continue
    if ! git -C "$worktree_path" rev-parse --git-dir >/dev/null 2>&1; then
        echo "Git privacy gate cannot check worktree: $worktree_path" >&2
        exit 1
    fi
    configured_path=$(git -C "$worktree_path" config --get core.hooksPath || true)
    case "$configured_path" in
        ""|".githooks"|"$legacy_hooks_directory"|"$versions_directory"/*/hooks) ;;
        *)
            echo "Git privacy gate refuses to replace the existing worktree core.hooksPath: $worktree_path" >&2
            exit 1
            ;;
    esac

    if [ "$worktree_config_enabled" = "true" ]; then
        if git -C "$worktree_path" config --worktree --get core.hooksPath \
            >"$worktree_value_file" 2>/dev/null; then
            echo "Git privacy gate refuses to replace the worktree-specific core.hooksPath: $worktree_path" >&2
            exit 1
        fi
    fi

    effective_hooks_directory=$(
        git -C "$worktree_path" rev-parse --git-path hooks
    )
    case "$effective_hooks_directory" in
        /*) ;;
        *) effective_hooks_directory="$worktree_path/$effective_hooks_directory" ;;
    esac
    for existing_hook in "$effective_hooks_directory"/*; do
        [ -e "$existing_hook" ] || continue
        case "$existing_hook" in
            *.sample) continue ;;
        esac
        [ -x "$existing_hook" ] || continue
        hook_name=${existing_hook##*/}
        case "$configured_path:$hook_name" in
            .githooks:commit-msg|.githooks:pre-commit|.githooks:pre-push)
                source_hook="$repository_root/.githooks/$hook_name"
                if [ ! -f "$source_hook" ] ||
                    ! cmp -s "$source_hook" "$existing_hook"; then
                    echo "Git privacy gate found an executable hook with the same name but different contents; refusing to replace it: $existing_hook" >&2
                    exit 1
                fi
                continue
                ;;
            "$legacy_hooks_directory":commit-msg|"$legacy_hooks_directory":pre-commit|"$legacy_hooks_directory":pre-push) continue ;;
            "$versions_directory"/*/hooks:commit-msg|"$versions_directory"/*/hooks:pre-commit|"$versions_directory"/*/hooks:pre-push) continue ;;
        esac
        if [ -n "$configured_path" ]; then
            echo "Git privacy gate found an additional executable hook; refusing to disable it silently: $existing_hook" >&2
        else
            echo "Git privacy gate found an existing executable hook; refusing to disable it silently: $existing_hook" >&2
        fi
        exit 1
    done
done <"$worktree_list_file"

candidate_directory=$(mktemp -d "$versions_directory/.candidate.XXXXXX")
mkdir -p "$candidate_directory/hooks"
cp "$repository_root/scripts/git_privacy_gate.py" \
    "$candidate_directory/git_privacy_gate.py"
cp "$repository_root/.githooks/commit-msg" \
    "$candidate_directory/hooks/commit-msg"
cp "$repository_root/.githooks/pre-commit" \
    "$candidate_directory/hooks/pre-commit"
cp "$repository_root/.githooks/pre-push" \
    "$candidate_directory/hooks/pre-push"
chmod 600 "$candidate_directory/git_privacy_gate.py"
chmod 700 \
    "$candidate_directory/hooks/commit-msg" \
    "$candidate_directory/hooks/pre-commit" \
    "$candidate_directory/hooks/pre-push"

cmp -s \
    "$repository_root/scripts/git_privacy_gate.py" \
    "$candidate_directory/git_privacy_gate.py"
sh -n \
    "$candidate_directory/hooks/commit-msg" \
    "$candidate_directory/hooks/pre-commit" \
    "$candidate_directory/hooks/pre-push"

self_test_output=$(
    cd "$repository_root"
    python3 "$candidate_directory/git_privacy_gate.py" --range HEAD..HEAD
)
case "$self_test_output" in
    PRIVACY_GATE_PASS*) ;;
    *)
        echo "Git privacy gate candidate failed its self-test; the current version is unchanged." >&2
        exit 1
        ;;
esac

safe_message="$candidate_directory/synthetic-safe-message"
printf '%s\n' "synthetic safe installer message" >"$safe_message"
if safe_message_output=$(
    cd "$repository_root"
    "$candidate_directory/hooks/commit-msg" "$safe_message" 2>&1
); then
    safe_message_status=0
else
    safe_message_status=$?
fi
rm -f -- "$safe_message"
if [ "$safe_message_status" -ne 0 ]; then
    echo "Git privacy gate candidate commit-msg wrongly blocked a safe message; the current version is unchanged." >&2
    exit 1
fi
case "$safe_message_output" in
    *PRIVACY_GATE_PASS*) ;;
    *)
        echo "Git privacy gate candidate commit-msg gave unexpected pass output; the current version is unchanged." >&2
        exit 1
        ;;
esac

probe_message="$candidate_directory/synthetic-secret-message"
probe_secret="ghp_""AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
printf '%s\n' "synthetic installer probe $probe_secret" >"$probe_message"
if probe_output=$(
    cd "$repository_root"
    "$candidate_directory/hooks/commit-msg" "$probe_message" 2>&1
); then
    probe_status=0
else
    probe_status=$?
fi
rm -f -- "$probe_message"
if [ "$probe_status" -ne 2 ]; then
    echo "Git privacy gate candidate failed to block a synthetic credential; the current version is unchanged." >&2
    exit 1
fi
case "$probe_output" in
    *PRIVACY_GATE_BLOCKED*) ;;
    *)
        echo "Git privacy gate candidate gave unexpected block output; the current version is unchanged." >&2
        exit 1
        ;;
esac
case "$probe_output" in
    *"$probe_secret"*)
        echo "Git privacy gate candidate echoed the synthetic credential; the current version is unchanged." >&2
        exit 1
        ;;
esac

probe_repository="$candidate_directory/hook-probe-repository"
probe_remote="$candidate_directory/hook-probe-remote.git"
git init -q -b main "$probe_repository"
git -C "$probe_repository" config user.name "Privacy Gate Installer Probe"
git -C "$probe_repository" config user.email "privacy-gate@example.invalid"
git -C "$probe_repository" config commit.gpgSign false
mkdir -p "$probe_repository/no-implicit-hooks"
git -C "$probe_repository" config \
    core.hooksPath \
    "$probe_repository/no-implicit-hooks"
mkdir -p "$probe_repository/Sources"
printf '%s\n' "struct InstallerProbe {}" \
    >"$probe_repository/Sources/InstallerProbe.swift"
git -C "$probe_repository" add -A

if safe_pre_commit_output=$(
    cd "$probe_repository"
    "$candidate_directory/hooks/pre-commit" 2>&1
); then
    safe_pre_commit_status=0
else
    safe_pre_commit_status=$?
fi
if [ "$safe_pre_commit_status" -ne 0 ]; then
    echo "Git privacy gate candidate pre-commit wrongly blocked safe staged changes; the current version is unchanged." >&2
    exit 1
fi
case "$safe_pre_commit_output" in
    *PRIVACY_GATE_PASS*) ;;
    *)
        echo "Git privacy gate candidate pre-commit gave unexpected pass output; the current version is unchanged." >&2
        exit 1
        ;;
esac

git -C "$probe_repository" commit \
    --no-verify \
    -q \
    -m "synthetic safe hook probe"
git init -q --bare "$probe_remote"
git -C "$probe_repository" remote add origin "$probe_remote"
safe_probe_oid=$(git -C "$probe_repository" rev-parse HEAD)
zero_oid="0000000000000000000000000000000000000000"
if safe_pre_push_output=$(
    cd "$probe_repository"
    printf '%s\n' \
        "refs/heads/main $safe_probe_oid refs/heads/main $zero_oid" |
        "$candidate_directory/hooks/pre-push" origin 2>&1
); then
    safe_pre_push_status=0
else
    safe_pre_push_status=$?
fi
if [ "$safe_pre_push_status" -ne 0 ]; then
    echo "Git privacy gate candidate pre-push wrongly blocked safe history; the current version is unchanged." >&2
    exit 1
fi
case "$safe_pre_push_output" in
    *PRIVACY_GATE_PASS*) ;;
    *)
        echo "Git privacy gate candidate pre-push gave unexpected pass output; the current version is unchanged." >&2
        exit 1
        ;;
esac

mkdir -p "$probe_repository/private-evidence"
printf '%s\n' "synthetic private frame" \
    >"$probe_repository/private-evidence/frame.jpg"
git -C "$probe_repository" add -A

if pre_commit_output=$(
    cd "$probe_repository"
    "$candidate_directory/hooks/pre-commit" 2>&1
); then
    pre_commit_status=0
else
    pre_commit_status=$?
fi
if [ "$pre_commit_status" -ne 2 ]; then
    echo "Git privacy gate candidate pre-commit failed to block synthetic evidence; the current version is unchanged." >&2
    exit 1
fi
case "$pre_commit_output" in
    *PRIVACY_GATE_BLOCKED*) ;;
    *)
        echo "Git privacy gate candidate pre-commit gave unexpected block output; the current version is unchanged." >&2
        exit 1
        ;;
esac

git -C "$probe_repository" commit \
    --no-verify \
    -q \
    -m "synthetic hook probe"
probe_oid=$(git -C "$probe_repository" rev-parse HEAD)
if pre_push_output=$(
    cd "$probe_repository"
    printf '%s\n' \
        "refs/heads/main $probe_oid refs/heads/main $zero_oid" |
        "$candidate_directory/hooks/pre-push" origin 2>&1
); then
    pre_push_status=0
else
    pre_push_status=$?
fi
if [ "$pre_push_status" -ne 2 ]; then
    echo "Git privacy gate candidate pre-push failed to block synthetic history; the current version is unchanged." >&2
    exit 1
fi
case "$pre_push_output" in
    *PRIVACY_GATE_BLOCKED*) ;;
    *)
        echo "Git privacy gate candidate pre-push gave unexpected block output; the current version is unchanged." >&2
        exit 1
        ;;
esac
rm -rf -- "$probe_repository" "$probe_remote"

version_name="version-$(date -u +%Y%m%dT%H%M%SZ)-$$"
version_directory="$versions_directory/$version_name"
mv "$candidate_directory" "$version_directory"
candidate_directory=
hooks_directory="$version_directory/hooks"

# Git itself locks and atomically replaces this single common-config write; every worktree inherits it.
git -C "$repository_root" config --local core.hooksPath "$hooks_directory"

while IFS= read -r worktree_path; do
    [ -n "$worktree_path" ] || continue
    effective_path=$(git -C "$worktree_path" config --get core.hooksPath || true)
    if [ "$effective_path" != "$hooks_directory" ]; then
        echo "Git privacy gate install failed: worktree did not inherit the shared gate: $worktree_path" >&2
        exit 1
    fi
done <"$worktree_list_file"

echo "Git privacy gate enabled for all worktrees of this repository: $version_name"
