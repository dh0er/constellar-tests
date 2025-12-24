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

# Ensure we run the agent *inside* the target repository checkout.
if [[ -n "${TARGET_WORKDIR}" ]]; then
    cd "${TARGET_WORKDIR}"
fi

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

PROMPT="$(cat <<'EOF'
You are operating in a GitHub Actions runner.

The GitHub CLI is available as `gh` and authenticated via `GH_TOKEN`. Git is available.

IMPORTANT: There are TWO repositories involved:
1) RUN_REPOSITORY: where this GitHub Actions workflow_run happened (where GH_RUN_ID/GH_RUN_URL point).
2) TARGET_REPOSITORY: the repository whose code you must change. You are currently running with your working directory set to the TARGET repo checkout. Do NOT modify files outside the target repo checkout.

There may also be a SOURCE_REPOSITORY that originally triggered the tests run (e.g. a different repo dispatching into RUN_REPOSITORY). If SOURCE_REPOSITORY + SOURCE_PR_NUMBER are present, treat that as the authoritative "PR association".

IMPORTANT CI ARCHITECTURE NOTE (do not ignore):
- The workflows in RUN_REPOSITORY often execute commands that are defined inside TARGET_REPOSITORY workflows.
- Concretely, wrapper workflows in RUN_REPOSITORY run a Ruby interpreter (`.github/scripts/run_workflow_run_steps.rb`) which loads a TARGET workflow YAML like:
  - `repo/.github/workflows/tests-android.yml`
  - `repo/.github/workflows/tests-ios.yml`
  - `repo/.github/workflows/tests-web.yml`
  and executes ONLY the `run:` steps for a given job.
- Therefore, some failures that look like "CI infra" (adb/simulator/tooling) can be ACTIONABLE by changing TARGET workflow `run:` steps or scripts referenced by them (still within TARGET_REPOSITORY).
- When diagnosing a failing platform workflow, always determine whether the failure came from:
  1) a wrapper step in RUN_REPOSITORY (e.g. an action like `android-emulator-runner`), or
  2) a `run:` step interpreted from TARGET workflow YAML / scripts in TARGET_REPOSITORY.
  You should fix issues in TARGET workflow/scripts whenever the failing behavior originates there.

# Auth
- `GH_TOKEN` is set for GitHub API/PR actions.
- If `TARGET_GH_TOKEN` is set, the script has already configured the target repo's `origin` remote to use HTTPS token auth (to avoid "deploy key is read-only" push failures).

# Context (values)
- RUN_REPOSITORY: __RUN_REPOSITORY_VALUE__
- Workflow Run ID (RUN_REPOSITORY): __GH_RUN_ID_VALUE__
- Workflow Run URL (RUN_REPOSITORY): __GH_RUN_URL_VALUE__
- Associated PR Number (RUN_REPOSITORY, may be empty): __RUN_PR_NUMBER_VALUE__
- Downloaded workflow artifacts dir (RUN_REPOSITORY, may be empty): __RUN_ARTIFACTS_DIR_VALUE__

- TARGET_REPOSITORY: __TARGET_REPOSITORY_VALUE__
- Target owner: __TARGET_OWNER_VALUE__
- Target repo: __TARGET_REPO_VALUE__
- Target default branch: __TARGET_DEFAULT_BRANCH_VALUE__
- Fix Branch Prefix: __BRANCH_PREFIX_VALUE__

- SOURCE_REPOSITORY (may be empty): __SOURCE_REPOSITORY_VALUE__
- Source ref (may be empty): __SOURCE_REF_VALUE__
- Source sha (may be empty): __SOURCE_SHA_VALUE__
- Source PR number (may be empty): __SOURCE_PR_NUMBER_VALUE__
- PR repository to use for PR actions (PR_REPOSITORY): __PR_REPOSITORY_VALUE__
- Effective PR number to use (PR_NUMBER, derived from source or run): __PR_NUMBER_VALUE__

# Goal:
- Implement an end-to-end CI fix flow for a failed workflow run.
  - If the run is associated with a PR (either PR_NUMBER from SOURCE_REPOSITORY context or RUN_REPOSITORY linkage): fix the PR with minimal changes, preferring to push fixes directly to the PR head branch when safe (details below).
  - If the run is NOT associated with a PR: create a fix branch off the default branch and open a PR back into the default branch.

# Requirements:
1) Determine whether this failure is tied to a PR:
   - If SOURCE_PR_NUMBER is non-empty, treat the failure as PR-associated in PR_REPOSITORY (this is expected for cross-repo dispatch).
   - Else, if RUN_PR_NUMBER is non-empty, treat it as PR-associated in RUN_REPOSITORY.
   - Else, treat it as not PR-associated.
2) If tied to a PR:
   - Determine the PR base and head branches. Let HEAD_REF be the PR's head branch.
   - PR context review (required before making any code changes):
     - Fetch PR metadata from PR_REPOSITORY (via `gh api repos/$PR_REPOSITORY/pulls/$PR_NUMBER`) and record:
       - PR title, state, base ref, head ref, head repo, and head sha.
     - Read the PR discussion/history to understand previous fixes and constraints:
       - Review the latest ~50 issue comments: `gh api repos/$PR_REPOSITORY/issues/$PR_NUMBER/comments --paginate`
       - Review the PR commits and recent diffs: `gh pr view "$PR_NUMBER" --repo "$PR_REPOSITORY" --json commits,files`
       - If a `cursor[bot]` comment exists, read it fully and treat it as prior fix context (do not duplicate work).
     - Bugbot comments (required, pre-change only; do NOT poll after pushing):
       - The PR may already contain bug review bot comments (e.g. "bugbot") that are NEW relative to the current PR head commit.
       - Define PR_HEAD_SHA from the PR metadata and compute PR_HEAD_COMMIT_TIME_UTC via:
         - `gh api repos/$PR_REPOSITORY/commits/$PR_HEAD_SHA --jq '.commit.committer.date // .commit.author.date'`
       - From the PR issue comments, identify bugbot comments using heuristics:
         - commenter login contains "bugbot" (case-insensitive), OR
         - comment body mentions "bugbot" (case-insensitive).
       - Determine whether bugbot comments are "new" (need action) using BOTH of these rules (use a small slack window of ~2 minutes to avoid clock/ordering edge cases):
         - Rule A (time-based): bugbot comment created_at >= PR_HEAD_COMMIT_TIME_UTC - slack
         - Rule B (last-comment-based): the MOST RECENT PR comment is a bugbot comment, AND PR_HEAD_COMMIT_TIME_UTC <= that comment's created_at + slack (meaning: no commits were pushed after the bugbot comment)
       - Ignore bugbot comments that match neither Rule A nor Rule B ("old bugbot comments").
       - For each NEW bugbot comment (Rule A or Rule B): if it contains clear, actionable issues fixable in TARGET_REPOSITORY (formatting, analyzer/lint, obvious bug, test reliability, workflow `run:` steps/scripts in TARGET repo, etc.), address them with minimal changes as part of this run BEFORE tackling workflow failures.
       - If a NEW bugbot comment is non-actionable or unclear, explicitly say so later in your PR summary comment and link to it.
     - Summarize in 2–4 bullets what has already been tried/changed and what remains failing, before proposing new edits.
   - Decide where to push fixes:
     - First, fetch PR metadata from PR_REPOSITORY (via `gh api repos/$PR_REPOSITORY/pulls/$PR_NUMBER`) and determine:
       - PR_HEAD_REPO = `.head.repo.full_name`
       - HEAD_REF = `.head.ref`
       - IS_FORK = `.head.repo.fork`
     - If HEAD_REF already starts with the Fix Branch Prefix (e.g. `ci-fix/...`), PR_HEAD_REPO equals TARGET_REPOSITORY, and IS_FORK is false, then treat HEAD_REF as the fix branch and push commits directly to it so the PR updates immediately. Do NOT create a second branch like `ci-fix/ci-fix-...` in this case.
     - Otherwise, maintain a persistent fix branch for this HEAD_REF using the Fix Branch Prefix from Context (e.g. `${BRANCH_PREFIX}/${HEAD_REF}`), create it if missing, update it otherwise, and push changes to origin.
   - Attempt to resolve the CI failure with minimal, targeted edits consistent with the repo's style.
   - PR comment policy (Option C: concise, but complete):
     - Post or update a SINGLE `cursor[bot]` PR comment that contains the same information as your final report, in a concise form that fits in a GitHub comment.
   - The comment MUST include:
       - Root cause summary
       - What changed (files / behavior)
       - Branch/push strategy (where you pushed, commit SHA)
       - Verification results (branch tip, comment updated)
       - All downstream failures handled (each workflow: actionable fix or classification + mitigation notes)
       - A unique marker line EXACTLY like: `cursor-agent-run-id: __GH_RUN_ID_VALUE__`
       - Links:
         - GH_RUN_URL (workflow run): __GH_RUN_URL_VALUE__
         - If using a separate fix branch, include a compare link to quick-create a PR
       - A note telling the reader where to find full details:
         - "Full logs and artifacts are attached to the workflow run (see GH_RUN_URL) and downloaded under RUN_ARTIFACTS_DIR in the agent run."
     - If you pushed directly to HEAD_REF: the comment should explicitly say the PR head branch was updated.
     - If you used a separate persistent fix branch: do NOT create a PR; instead include the compare link.
     - Keep the comment compact (avoid pasting huge logs). If the full output would be long, include only the summary + links above.
   - Verification (required): after pushing and commenting, verify (via GitHub API) that:
     - the remote branch tip SHA is the expected commit SHA
     - the PR comment exists/was updated
     If any of these fail, do not claim success.
3) If NOT tied to a PR:
   - Treat the TARGET default branch as the failing base. Create a fix branch from the TARGET default branch using the Fix Branch Prefix and the run id for uniqueness.
   - Attempt to resolve the CI failure with minimal, targeted edits consistent with the repo's style.
   - If and only if you made a safe, actionable fix: push the fix branch and create a PR back into the default branch with a concise title/body.
4) If no actionable fix is possible:
   - Make no code changes.
   - Still provide a clear, explicit final report in your output explaining WHY (missing artifacts, auth/permission issue, no failing downstream workflows, etc.).
   - If PR-associated: still post/update a SINGLE `cursor[bot]` PR comment explaining the decision (see PR comment policy above). Do NOT silently exit.

# Inputs and conventions:
- Use `gh api`, `gh run view`, `gh pr view`, `gh pr diff`, `gh pr list`, `gh run download`, and git commands as needed.
- NEVER run `gh run view` without a run id argument (use the run id from Context).
- NEVER put `--repo ...` on its own line; it must be part of the same `gh ...` command.
- For ANY `gh` command, always target the intended repo explicitly:
  - Run/workflow metadata MUST target RUN_REPOSITORY:
    - Prefer explicit REST endpoints like `gh api repos/$RUN_REPOSITORY/actions/runs/$GH_RUN_ID`
    - Or pass `--repo "$RUN_REPOSITORY"` (e.g. `gh run view "$GH_RUN_ID" --repo "$RUN_REPOSITORY"`)
  - PR metadata / commenting MUST target PR_REPOSITORY:
    - Use `--repo "$PR_REPOSITORY"` for `gh pr view`, `gh pr comment`, etc.
  - Target-repo PR creation MUST target TARGET_REPOSITORY:
    - Pass `--repo "$TARGET_REPOSITORY"` for `gh pr create`, `gh pr view`, etc.
- Never run `gh pr create` without an explicit `--repo` flag.
- When pushing commits / creating PRs, operate on TARGET_REPOSITORY (your current working directory is the target repo checkout).
- Avoid duplicate comments; if a previous bot comment exists, update it instead of posting a new one.

# Full logs for downstream "dispatch" workflows (if present):
- If the failing run is a dispatcher (e.g. "Run All Tests"), it may have uploaded artifacts like:
  - `downstream-logs-tests-ios.yml-run-<id>.zip`
  - `downstream-logs-tests-web.yml-run-<id>.zip`
  - `downstream-logs-tests-android.yml-run-<id>.zip`
- It may also have uploaded downstream run artifacts captured by platform workflows (screenshots, videos, etc.) like:
  - `downstream-artifacts-tests-web.yml-run-<id>/.../*.zip`
  - `downstream-artifacts-tests-android.yml-run-<id>/.../*.zip`
- These artifacts (if any) have already been downloaded into `__RUN_ARTIFACTS_DIR_VALUE__`.
- Prefer inspecting those ZIPs/artifact bundles to avoid truncated combined logs.

# Multi-failure handling (critical):
- This run can have multiple failing downstream workflows (e.g. web AND android). You MUST handle ALL of them:
  - Enumerate all failing downstream workflows by inspecting the downloaded artifacts directory for `downstream-logs-*.zip` and `downstream-artifacts-*`.
  - For each failing workflow, inspect logs AND any attached artifacts (screenshots/recordings) before deciding what to change.
  - If a failure looks infra-related (e.g. adb daemon not reachable / simulator missing):
    - First, trace whether it came from a wrapper action step (RUN_REPOSITORY) vs a TARGET `run:` step/script.
    - If it came from TARGET workflow/scripts, treat it as actionable in TARGET_REPOSITORY and fix it there.
    - Only classify it as non-actionable-from-target if it is clearly caused by the runner/action environment and cannot be mitigated by TARGET changes.
  - Do not stop after fixing the first failure unless you have verified no other workflows failed.

# Deliverables when updates occur:
- If PR-associated:
  - If HEAD_REF starts with the fix prefix and is not a fork: pushed commits directly to HEAD_REF and posted/updated a single PR comment.
  - Otherwise: pushed commits to the persistent fix branch for the PR head, and posted/updated a single PR comment with a quick-create compare link.
- If not PR-associated: a PR opened from the fix branch into the default branch.
EOF
)"

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

# Retry transient Cursor connectivity errors (e.g., "ConnectError: [unavailable]").
max_attempts="${CURSOR_AGENT_MAX_ATTEMPTS:-4}"
attempt=1
sleep_seconds="${CURSOR_AGENT_RETRY_SLEEP_SECONDS:-10}"

while true; do
    echo "Running cursor-agent (attempt ${attempt}/${max_attempts})..."
    set +e
    # Stream logs live (so GH Actions doesn't look "stuck") and avoid buffering the
    # entire output in memory (which can truncate/kill long runs).
    OUTPUT_FILE="$(mktemp -t cursor-agent-output.XXXXXX)"
    CURSOR_AGENT_AUTOMATION=true cursor-agent -p "$PROMPT" --force --model "$MODEL" --output-format=text 2>&1 | tee "$OUTPUT_FILE"
    # With `set -o pipefail`, the pipeline exit code may be from `tee`. We want
    # cursor-agent's status (first command in pipeline).
    EXIT_CODE="${PIPESTATUS[0]}"
    echo "cursor-agent exit code: ${EXIT_CODE}"
    set -e

    if [[ $EXIT_CODE -eq 0 ]]; then
        # Guardrail: if this run is PR-associated, the agent MUST have posted/updated
        # a PR comment containing the run id marker; otherwise treat as failure so
        # we never "succeed while doing nothing".
        if [[ -n "${PR_NUMBER:-}" ]] && [[ -n "${PR_REPOSITORY:-}" ]] && command -v gh >/dev/null 2>&1; then
            if ! gh api "repos/${PR_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate --jq ".[] | select(.user.login==\"cursor[bot]\") | .body" 2>/dev/null \
                | grep -q "cursor-agent-run-id: ${GH_RUN_ID:-}"; then
                echo "Error: cursor-agent exited 0 but did not post a cursor[bot] PR comment with marker: cursor-agent-run-id: ${GH_RUN_ID:-}"
                echo "PR_REPOSITORY=${PR_REPOSITORY} PR_NUMBER=${PR_NUMBER}"
                rm -f "$OUTPUT_FILE" || true
                exit 1
            fi
        fi
        rm -f "$OUTPUT_FILE" || true
        break
    fi

    if grep -q "ConnectError: \\[unavailable\\]" "$OUTPUT_FILE" && [[ $attempt -lt $max_attempts ]]; then
        echo "cursor-agent connection unavailable; retrying in ${sleep_seconds}s..."
        rm -f "$OUTPUT_FILE" || true
        sleep "$sleep_seconds"
        attempt=$((attempt + 1))
        sleep_seconds=$((sleep_seconds * 2))
        continue
    fi

    rm -f "$OUTPUT_FILE" || true
    exit "$EXIT_CODE"
done
