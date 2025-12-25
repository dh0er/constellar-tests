#!/bin/bash
set -euo pipefail

normalize_repo_slug() {
    # Accept:
    # - owner/repo
    # - https://github.com/owner/repo(.git)
    # - git@github.com:owner/repo(.git)
    local input="${1:-}"
    input="${input#https://github.com/}"
    input="${input#http://github.com/}"
    input="${input#git@github.com:}"
    input="${input%.git}"
    echo "$input"
}

RUN_REPOSITORY="$(normalize_repo_slug "${RUN_REPOSITORY:-${GITHUB_REPOSITORY:-}}")"

# The workflow run lives in RUN_REPOSITORY (this/orchestrator repo).
RUN_OWNER=""
RUN_REPO=""
if [[ -n "${RUN_REPOSITORY}" ]]; then
    RUN_OWNER="${RUN_REPOSITORY%%/*}"
    RUN_REPO="${RUN_REPOSITORY##*/}"
fi

# The code we should fix lives in GH_REPOSITORY (target repo).
TARGET_REPOSITORY="$(normalize_repo_slug "${GH_REPOSITORY:-}")"
TARGET_OWNER="${GH_REPOSITORY_OWNER:-}"
TARGET_REPO="${GH_REPOSITORY_NAME:-}"

if [[ -z "${TARGET_REPO}" ]] && [[ -n "${TARGET_REPOSITORY}" ]]; then
    TARGET_REPO="${TARGET_REPOSITORY##*/}"
fi

if [[ -z "${TARGET_OWNER}" ]] && [[ -n "${TARGET_REPOSITORY}" ]]; then
    TARGET_OWNER="${TARGET_REPOSITORY%%/*}"
fi

TARGET_WORKDIR="${TARGET_WORKDIR:-}"

# Verify required variables are set
if [[ -z "${RUN_OWNER}" ]] || [[ -z "${RUN_REPO}" ]]; then
    echo "Error: RUN_REPOSITORY must be set (e.g. owner/repo)"
    exit 1
fi

if [[ -z "${TARGET_OWNER}" ]] || [[ -z "${TARGET_REPO}" ]]; then
    echo "Error: GH_REPOSITORY (and/or GH_REPOSITORY_OWNER/GH_REPOSITORY_NAME) must be set for the target repo"
    exit 1
fi

# Prefer the run that triggered the workflow (passed from the workflow event).
# Fall back to "most recent failed run" if not provided.
if [[ -z "${GH_RUN_ID:-}" ]]; then
    RUN_INFO=$(gh api "repos/$RUN_OWNER/$RUN_REPO/actions/runs" -f status=completed -f per_page=100 --jq '
      .workflow_runs
      | map(select(.conclusion=="failure" or .conclusion=="timed_out"))
      | first
      | "\(.id) \(.html_url)"
    ')

    if [[ -n "${RUN_INFO}" ]]; then
        GH_RUN_ID=$(echo "$RUN_INFO" | awk '{print $1}')
        GH_RUN_URL=$(echo "$RUN_INFO" | awk '{print $2}')
    else
        echo "Warning: No failed workflow runs found"
        GH_RUN_ID=""
        GH_RUN_URL=""
    fi
fi

# If we have a run id but no url, fetch it.
if [[ -n "${GH_RUN_ID:-}" ]] && [[ -z "${GH_RUN_URL:-}" ]]; then
    GH_RUN_URL=$(gh api "repos/$RUN_OWNER/$RUN_REPO/actions/runs/$GH_RUN_ID" --jq '.html_url // ""')
fi

# Determine if this run is associated with a PR in the RUN_REPOSITORY (often empty for workflow_dispatch).
RUN_PR_NUMBER=""
if [[ -n "${GH_RUN_ID:-}" ]]; then
    RUN_PR_NUMBER=$(gh api "repos/$RUN_OWNER/$RUN_REPO/actions/runs/$GH_RUN_ID" --jq '.pull_requests[0].number // ""')
fi

# Download workflow artifacts for this run (if available). This is especially useful
# for "Run All Tests" which may attach full downstream logs as artifacts.
RUN_ARTIFACTS_DIR="${RUN_ARTIFACTS_DIR:-}"
if [[ -z "${RUN_ARTIFACTS_DIR}" ]] && [[ -n "${GH_RUN_ID:-}" ]]; then
    RUN_ARTIFACTS_DIR="${RUNNER_TEMP:-/tmp}/run-artifacts-${RUN_OWNER}-${RUN_REPO}-${GH_RUN_ID}"
fi

if [[ -n "${GH_RUN_ID:-}" ]] && [[ -n "${RUN_ARTIFACTS_DIR:-}" ]]; then
    mkdir -p "${RUN_ARTIFACTS_DIR}" || true
    # Don't fail the whole agent run if artifacts can't be fetched (e.g. permissions).
    gh run download "${GH_RUN_ID}" --repo "${RUN_OWNER}/${RUN_REPO}" --dir "${RUN_ARTIFACTS_DIR}" >/dev/null 2>&1 || true
fi

# Optional: Extract source repo context that was recorded by the "Run All Tests" workflow.
# This is critical when a PR in a *different* repo (e.g. source/target) triggered this run,
# because workflow_run payloads in this repo won't include PR linkage.
SOURCE_REPOSITORY=""
SOURCE_REF=""
SOURCE_SHA=""
SOURCE_PR_NUMBER=""
SOURCE_CONTEXT_PATH=""
if [[ -n "${RUN_ARTIFACTS_DIR:-}" ]] && [[ -d "${RUN_ARTIFACTS_DIR:-}" ]]; then
    SOURCE_CONTEXT_PATH="$(
        find "${RUN_ARTIFACTS_DIR}" -maxdepth 4 -type f -name "source_context.json" 2>/dev/null \
            | head -n 1 \
            || true
    )"
fi

if [[ -n "${SOURCE_CONTEXT_PATH:-}" ]] && [[ -f "${SOURCE_CONTEXT_PATH:-}" ]]; then
    # Prefer jq; fall back to python if jq isn't available.
    if command -v jq >/dev/null 2>&1; then
        SOURCE_REPOSITORY="$(jq -r '.source_repo // ""' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
        SOURCE_REF="$(jq -r '.source_ref // ""' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
        SOURCE_SHA="$(jq -r '.source_sha // ""' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
        SOURCE_PR_NUMBER="$(jq -r '.source_pr // ""' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
        SOURCE_REPOSITORY="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])) or {}).get("source_repo",""))' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
        SOURCE_REF="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])) or {}).get("source_ref",""))' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
        SOURCE_SHA="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])) or {}).get("source_sha",""))' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
        SOURCE_PR_NUMBER="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])) or {}).get("source_pr",""))' "${SOURCE_CONTEXT_PATH}" 2>/dev/null || true)"
    fi
fi

# Prefer a PR association from source context when available (common for cross-repo dispatch).
PR_NUMBER="${SOURCE_PR_NUMBER:-}"
if [[ -z "${PR_NUMBER:-}" ]]; then
    PR_NUMBER="${RUN_PR_NUMBER:-}"
fi

# If source repository isn't provided, assume PR (if any) lives in the target repo.
PR_REPOSITORY="$(normalize_repo_slug "${SOURCE_REPOSITORY:-${TARGET_REPOSITORY}}")"

# Resolve the prompt template file path BEFORE changing directories
# (the prompt file is in the orchestrator repo, not the target repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_TEMPLATE_FILE="${SCRIPT_DIR}/../prompts/cursor-agent.md"
# Resolve to absolute path (handle .. in path)
if command -v realpath >/dev/null 2>&1; then
    PROMPT_TEMPLATE_FILE="$(realpath "${PROMPT_TEMPLATE_FILE}" 2>/dev/null || echo "${PROMPT_TEMPLATE_FILE}")"
else
    # Fallback: resolve manually by normalizing the path
    PROMPT_TEMPLATE_FILE="$(cd "$(dirname "${PROMPT_TEMPLATE_FILE}")" 2>/dev/null && pwd)/$(basename "${PROMPT_TEMPLATE_FILE}")" || PROMPT_TEMPLATE_FILE="${SCRIPT_DIR}/../prompts/cursor-agent.md"
fi
if [[ ! -f "${PROMPT_TEMPLATE_FILE}" ]]; then
    echo "Error: cursor-agent prompt template not found: ${PROMPT_TEMPLATE_FILE}"
    echo "Script directory: ${SCRIPT_DIR}"
    echo "Looking for: ${SCRIPT_DIR}/../prompts/cursor-agent.md"
    echo "Current working directory: $(pwd)"
    exit 1
fi

# Ensure we run the agent *inside* the target repository checkout.
if [[ -n "${TARGET_WORKDIR}" ]]; then
    cd "${TARGET_WORKDIR}"
fi

# The agent must NOT mutate remote state (push/comment) during its run.
# Instead, it should append those commands to a post-run script which will be
# executed after cursor-agent exits (by the workflow).
POST_RUN_SCRIPT="${CURSOR_AGENT_POST_RUN_SCRIPT:-"$(pwd)/.cursor-agent-post-run.sh"}"
export CURSOR_AGENT_POST_RUN_SCRIPT="${POST_RUN_SCRIPT}"

# Create/overwrite the post-run script with a safe, deterministic header.
cat > "${POST_RUN_SCRIPT}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# This script is generated by cursor-agent. It is executed AFTER cursor-agent exits.
# It should contain ONLY commands that were intentionally deferred (git push, PR comments, etc.).
SH

# Ensure git commits work in the *target* clone.
# GitHub Actions runners often have no global author identity configured, and
# `git config user.*` done in the orchestrator checkout does not apply here.
# Use per-command environment variables so we never touch git config.
if [[ -z "${GIT_AUTHOR_NAME:-}" ]]; then
    export GIT_AUTHOR_NAME="${CURSOR_GIT_AUTHOR_NAME:-Cursor Agent}"
fi
if [[ -z "${GIT_AUTHOR_EMAIL:-}" ]]; then
    export GIT_AUTHOR_EMAIL="${CURSOR_GIT_AUTHOR_EMAIL:-cursoragent@cursor.com}"
fi
if [[ -z "${GIT_COMMITTER_NAME:-}" ]]; then
    export GIT_COMMITTER_NAME="${CURSOR_GIT_COMMITTER_NAME:-${GIT_AUTHOR_NAME}}"
fi
if [[ -z "${GIT_COMMITTER_EMAIL:-}" ]]; then
    export GIT_COMMITTER_EMAIL="${CURSOR_GIT_COMMITTER_EMAIL:-${GIT_AUTHOR_EMAIL}}"
fi

# Persist git author/committer identity for the post-run script (it runs in a new step).
{
    echo ""
    echo "export GIT_AUTHOR_NAME=$(printf '%q' "${GIT_AUTHOR_NAME}")"
    echo "export GIT_AUTHOR_EMAIL=$(printf '%q' "${GIT_AUTHOR_EMAIL}")"
    echo "export GIT_COMMITTER_NAME=$(printf '%q' "${GIT_COMMITTER_NAME}")"
    echo "export GIT_COMMITTER_EMAIL=$(printf '%q' "${GIT_COMMITTER_EMAIL}")"
    echo ""
} >> "${POST_RUN_SCRIPT}"

# Returns 0 if the post-run script contains actionable commands, 1 otherwise.
post_run_script_has_actionable_commands() {
    local script_path="${1:-}"
    if [[ -z "${script_path}" ]] || [[ ! -f "${script_path}" ]]; then
        return 1
    fi
    # "Actionable" = any non-empty line that is not:
    # - a comment
    # - a shebang
    # - set -euo pipefail
    # - export statements (we always add those)
    grep -qvE '^\s*($|#|#!/usr/bin/env bash|set -euo pipefail|export\s+)' "${script_path}"
}

run_post_run_script_if_actionable() {
    local script_path="${1:-}"
    if post_run_script_has_actionable_commands "${script_path}"; then
        echo "Detected actionable deferred commands in ${script_path}. Executing now and stopping further cursor-agent attempts."
        chmod +x "${script_path}" || true
        bash "${script_path}"
        return 0
    fi
    return 1
}

# If a token is provided for the target repo, prefer HTTPS auth for pushes.
# This avoids "deploy key is read-only" failures when the clone used SSH.
if [[ -n "${TARGET_GH_TOKEN:-}" ]]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Avoid printing the token by ensuring xtrace is off (script doesn't use -x).
        git remote set-url origin "https://x-access-token:${TARGET_GH_TOKEN}@github.com/${TARGET_OWNER}/${TARGET_REPO}.git" >/dev/null 2>&1 || true
    fi
fi

# Default branch is the fallback base when there is no associated PR.
# In this workflow, GH_TOKEN is often the workflow's GITHUB_TOKEN which may not
# have access to the target repo via API (404). Prefer deriving from the local
# clone, and only use the API if it works.
TARGET_DEFAULT_BRANCH="${TARGET_DEFAULT_BRANCH:-}"
if [[ -z "$TARGET_DEFAULT_BRANCH" ]]; then
    # 1) Try from local git remote HEAD (works with deploy-key clones).
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        TARGET_DEFAULT_BRANCH="$(
            git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
                | sed 's#^origin/##' \
                || true
        )"
    fi

    # 2) Fallback to GitHub API if accessible.
    if [[ -z "$TARGET_DEFAULT_BRANCH" ]]; then
        TARGET_DEFAULT_BRANCH="$(
            gh api "repos/$TARGET_OWNER/$TARGET_REPO" --jq '.default_branch' 2>/dev/null || true
        )"
    fi

    # 3) Last-resort fallback.
    if [[ -z "$TARGET_DEFAULT_BRANCH" ]]; then
        TARGET_DEFAULT_BRANCH="main"
    fi
fi

# Read the prompt template (path was resolved before changing directories)
PROMPT="$(cat "${PROMPT_TEMPLATE_FILE}")"

PROMPT="${PROMPT//__RUN_REPOSITORY_VALUE__/${RUN_REPOSITORY}}"
PROMPT="${PROMPT//__GH_RUN_ID_VALUE__/${GH_RUN_ID:-}}"
PROMPT="${PROMPT//__GH_RUN_URL_VALUE__/${GH_RUN_URL:-}}"
PROMPT="${PROMPT//__RUN_PR_NUMBER_VALUE__/${RUN_PR_NUMBER:-}}"
PROMPT="${PROMPT//__RUN_ARTIFACTS_DIR_VALUE__/${RUN_ARTIFACTS_DIR:-}}"
PROMPT="${PROMPT//__TARGET_REPOSITORY_VALUE__/${TARGET_REPOSITORY}}"
PROMPT="${PROMPT//__TARGET_OWNER_VALUE__/${TARGET_OWNER}}"
PROMPT="${PROMPT//__TARGET_REPO_VALUE__/${TARGET_REPO}}"
PROMPT="${PROMPT//__TARGET_DEFAULT_BRANCH_VALUE__/${TARGET_DEFAULT_BRANCH}}"
PROMPT="${PROMPT//__BRANCH_PREFIX_VALUE__/${BRANCH_PREFIX}}"
PROMPT="${PROMPT//__SOURCE_REPOSITORY_VALUE__/${SOURCE_REPOSITORY:-}}"
PROMPT="${PROMPT//__SOURCE_REF_VALUE__/${SOURCE_REF:-}}"
PROMPT="${PROMPT//__SOURCE_SHA_VALUE__/${SOURCE_SHA:-}}"
PROMPT="${PROMPT//__SOURCE_PR_NUMBER_VALUE__/${SOURCE_PR_NUMBER:-}}"
PROMPT="${PROMPT//__PR_REPOSITORY_VALUE__/${PR_REPOSITORY:-}}"
PROMPT="${PROMPT//__PR_NUMBER_VALUE__/${PR_NUMBER:-}}"
PROMPT="${PROMPT//__POST_RUN_SCRIPT_VALUE__/${POST_RUN_SCRIPT}}"

# Write the expanded prompt to a temp file so we don't have to pass the full prompt on the command line.
PROMPT_FILE="$(mktemp -t cursor-agent-expanded-prompt.XXXXXX)"
printf '%s' "${PROMPT}" > "${PROMPT_FILE}"
trap 'rm -f "${PROMPT_FILE}" 2>/dev/null || true' EXIT

# Pass only a small instruction; the agent must read the full prompt from PROMPT_FILE.
PROMPT_POINTER="Read and follow ALL instructions from this file (treat it as the system prompt): ${PROMPT_FILE}"

echo "=== Cursor-agent context dump (pre-run) ==="
echo "RUN_REPOSITORY=${RUN_REPOSITORY}  GH_RUN_ID=${GH_RUN_ID:-}  GH_RUN_URL=${GH_RUN_URL:-}"
echo "RUN_PR_NUMBER=${RUN_PR_NUMBER:-}  SOURCE_PR_NUMBER=${SOURCE_PR_NUMBER:-}  EFFECTIVE_PR_NUMBER=${PR_NUMBER:-}"
echo "TARGET_REPOSITORY=${TARGET_REPOSITORY}  TARGET_DEFAULT_BRANCH=${TARGET_DEFAULT_BRANCH}"
echo "SOURCE_REPOSITORY=${SOURCE_REPOSITORY:-}  SOURCE_REF=${SOURCE_REF:-}  SOURCE_SHA=${SOURCE_SHA:-}"
echo "PR_REPOSITORY=${PR_REPOSITORY:-}"
if [[ -n "${SOURCE_CONTEXT_PATH:-}" ]] && [[ -f "${SOURCE_CONTEXT_PATH:-}" ]]; then
    echo "SOURCE_CONTEXT_PATH=${SOURCE_CONTEXT_PATH}"
    echo "--- source_context.json ---"
    cat "${SOURCE_CONTEXT_PATH}" || true
    echo "--------------------------"
else
    echo "SOURCE_CONTEXT_PATH=(not found)"
fi
echo "========================================="

echo "cursor-agent path: $(command -v cursor-agent || echo 'not found')"
echo "cursor-agent version:"
cursor-agent --version 2>/dev/null || true

# Retry cursor-agent when it fails to do its job (exit non-zero, "successful" but
# missing expected PR side effects) or hangs.
#
# - A hang is defined as not finishing after 30 minutes.
# - Retry up to 3 times total (including the first attempt).
max_attempts="${CURSOR_AGENT_MAX_ATTEMPTS:-3}"
hang_timeout_minutes="${CURSOR_AGENT_HANG_TIMEOUT_MINUTES:-30}"
attempt=1
sleep_seconds="${CURSOR_AGENT_RETRY_SLEEP_SECONDS:-10}"

echo "cursor-agent hang timeout: ${hang_timeout_minutes} minutes"
echo "timeout path: $(command -v timeout || echo 'not found')"
echo "timeout version:"
timeout --version 2>/dev/null || true

while [[ $attempt -le $max_attempts ]]; do
    echo "Running cursor-agent (attempt ${attempt}/${max_attempts})..."

    # Stream logs live (so GH Actions doesn't look "stuck") and avoid buffering the
    # entire output in memory (which can truncate/kill long runs).
    OUTPUT_FILE="$(mktemp -t cursor-agent-output.XXXXXX)"

    # cursor-agent tends to buffer heavily when stdout isn't a TTY (common in CI),
    # which makes GitHub Actions appear "silent" for long stretches. Run it under a
    # pseudo-terminal when possible so progress logs flush incrementally.
    # Maximize immediate output:
    # - Use NDJSON streaming events (`--output-format=stream-json`)
    # - Emit partial text chunks as they are generated (`--stream-partial-output`)
    # Docs: https://cursor.com/docs/cli/reference/output-format
    CURSOR_AGENT_ARGS=(cursor-agent -p "$PROMPT_POINTER" --force --model "$MODEL" --print --output-format=stream-json)
    CURSOR_AGENT_RUNNER=("${CURSOR_AGENT_ARGS[@]}")
    if command -v script >/dev/null 2>&1; then
        # Linux (util-linux): script -q -e -c "<cmd>" /dev/null
        # macOS/BSD:          script -q /dev/null <cmd> [args...]
        if script -q -e -c "true" /dev/null >/dev/null 2>&1; then
            CURSOR_AGENT_CMD_STR="$(printf '%q ' "${CURSOR_AGENT_ARGS[@]}")"
            CURSOR_AGENT_RUNNER=(script -q -e -c "${CURSOR_AGENT_CMD_STR}" /dev/null)
        else
            CURSOR_AGENT_RUNNER=(script -q /dev/null "${CURSOR_AGENT_ARGS[@]}")
        fi
    fi

    set +e
    # Use `timeout` so the run is killed/retried if it exceeds the hang threshold.
    # `timeout` returns:
    # - 0 if command succeeded
    # - the command's exit code if it failed
    # - 124 if timed out (hang)
    # Important: when running under `script` (PTY), the child process may not exit
    # on TERM. Ensure we hard-kill after a short grace period so the loop can retry.
    # Wrap the *entire* logging pipeline inside `timeout`. Otherwise, if the wrapped
    # command leaves behind a child that keeps stdout open, the outer `tee`/pipe can
    # block forever even though `timeout` already fired.
    # cursor-agent emits NDJSON (stream-json). That output is useful for machines but noisy for humans.
    # Keep the raw stream in OUTPUT_FILE, but render a readable console view by extracting only the
    # "thinking delta" text fragments.
    STREAM_FILTER="${SCRIPT_DIR}/cursor_stream_filter.py"
    CURSOR_AGENT_AUTOMATION=true timeout --foreground --kill-after=30s "${hang_timeout_minutes}m" \
        bash -c 'set -o pipefail; out="$1"; filter="$2"; shift 2;
            if command -v python3 >/dev/null 2>&1 && [[ -f "$filter" ]]; then
                "$@" 2>&1 | tee "$out" | python3 -u "$filter"
            else
                "$@" 2>&1 | tee "$out"
            fi' \
        bash "$OUTPUT_FILE" "$STREAM_FILTER" "${CURSOR_AGENT_RUNNER[@]}"
    EXIT_CODE="$?"
    set -e

    echo "cursor-agent exit code: ${EXIT_CODE}"

    # Success criteria:
    # - cursor-agent exits 0
    # - AND it produced at least one actionable deferred command in POST_RUN_SCRIPT
    #
    # Rationale: "exit 0 but no deferred commands" usually means the agent didn't actually
    # take the required actions (push/comment/etc.) and we should retry.
    if [[ $EXIT_CODE -eq 0 ]]; then
        if post_run_script_has_actionable_commands "${POST_RUN_SCRIPT}"; then
            rm -f "$OUTPUT_FILE" || true
            break
        fi

        echo "cursor-agent exited 0 but produced no actionable commands in ${POST_RUN_SCRIPT}."

        # If this was the last attempt, fail with a clear error.
        if [[ $attempt -ge $max_attempts ]]; then
            echo "Error: cursor-agent exited successfully but produced no actionable commands on final attempt."
            rm -f "$OUTPUT_FILE" || true
            exit 1
        fi

        echo "Retrying because there are no actionable deferred commands..."
        rm -f "$OUTPUT_FILE" || true
        sleep 5
        attempt=$((attempt + 1))
        continue
    fi

    # Special case: if cursor-agent timed out but already produced actionable deferred commands,
    # execute them and stop retrying. This prevents running the agent again when it already has
    # enough information to proceed.
    if [[ $EXIT_CODE -eq 124 ]]; then
        if run_post_run_script_if_actionable "${POST_RUN_SCRIPT}"; then
            rm -f "$OUTPUT_FILE" || true
            exit 0
        fi
    fi

    # If this was the last attempt, fail with a clear error.
    if [[ $attempt -ge $max_attempts ]]; then
        if [[ $EXIT_CODE -eq 124 ]]; then
            echo "Error: cursor-agent hung (did not finish within ${hang_timeout_minutes} minutes) on final attempt."
        else
            echo "Error: cursor-agent failed with exit code ${EXIT_CODE} on final attempt."
        fi
        rm -f "$OUTPUT_FILE" || true
        exit 1
    fi

    # Retry strategy:
    # - For connectivity errors, keep exponential backoff.
    # - For hangs/other failures, retry quickly.
    if grep -q "ConnectError: \\[unavailable\\]" "$OUTPUT_FILE"; then
        echo "cursor-agent connection unavailable; retrying in ${sleep_seconds}s..."
        sleep "$sleep_seconds"
        sleep_seconds=$((sleep_seconds * 2))
    elif [[ $EXIT_CODE -eq 124 ]]; then
        echo "cursor-agent hung (>${hang_timeout_minutes}m); retrying..."
        sleep 5
    else
        echo "cursor-agent failed (exit code ${EXIT_CODE}); retrying..."
        sleep 5
    fi

    rm -f "$OUTPUT_FILE" || true
    attempt=$((attempt + 1))
done

# If we reached here, either:
# - cursor-agent succeeded and we `break`'d out of the loop, or
# - we exhausted retries and already `exit 1`'d above.
#
# In the success case, execute the deferred post-run script now. This is where
# pushes/PR comments happen (never during the agent run itself).
if post_run_script_has_actionable_commands "${POST_RUN_SCRIPT}"; then
    echo "Executing deferred post-run commands from ${POST_RUN_SCRIPT}..."
    echo "=== Deferred post-run script (sanitized) ==="
    # Avoid leaking secrets into CI logs. Redact common token patterns if present.
    if command -v sed >/dev/null 2>&1; then
        sed -E \
            -e 's#(https://x-access-token:)[^@]+@#\\1***@#g' \
            -e 's#\\b(ghp|github_pat)_[A-Za-z0-9_]+#\\1_***#g' \
            "${POST_RUN_SCRIPT}"
    else
        cat "${POST_RUN_SCRIPT}"
    fi
    echo "=== End deferred post-run script ==="
    chmod +x "${POST_RUN_SCRIPT}" || true
    bash "${POST_RUN_SCRIPT}"
else
    echo "Error: cursor-agent succeeded but produced no actionable deferred commands in ${POST_RUN_SCRIPT}."
    exit 1
fi
