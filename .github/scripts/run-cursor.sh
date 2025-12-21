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

# Determine if this run is associated with a PR (can be empty for push-to-main runs).
PR_NUMBER=""
if [[ -n "${GH_RUN_ID:-}" ]]; then
    PR_NUMBER=$(gh api "repos/$RUN_OWNER/$RUN_REPO/actions/runs/$GH_RUN_ID" --jq '.pull_requests[0].number // ""')
fi

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

# Auth
- `GH_TOKEN` is set for GitHub API/PR actions.
- If `TARGET_GH_TOKEN` is set, the script has already configured the target repo's `origin` remote to use HTTPS token auth (to avoid "deploy key is read-only" push failures).

# Context (values)
- RUN_REPOSITORY: __RUN_REPOSITORY_VALUE__
- Workflow Run ID (RUN_REPOSITORY): __GH_RUN_ID_VALUE__
- Workflow Run URL (RUN_REPOSITORY): __GH_RUN_URL_VALUE__
- Associated PR Number (RUN_REPOSITORY, may be empty): __PR_NUMBER_VALUE__

- TARGET_REPOSITORY: __TARGET_REPOSITORY_VALUE__
- Target owner: __TARGET_OWNER_VALUE__
- Target repo: __TARGET_REPO_VALUE__
- Target default branch: __TARGET_DEFAULT_BRANCH_VALUE__
- Fix Branch Prefix: __BRANCH_PREFIX_VALUE__

# Goal:
- Implement an end-to-end CI fix flow for a failed workflow run.
  - If the run is associated with a PR: create/update a persistent fix branch and comment on the PR with a quick-create compare link (do NOT create a PR directly).
  - If the run is NOT associated with a PR: create a fix branch off the default branch and open a PR back into the default branch.

# Requirements:
1) Inspect the failed workflow run and determine whether it is tied to a PR.
2) If tied to a PR:
   - Determine the PR base and head branches. Let HEAD_REF be the PR's head branch.
   - Maintain a persistent fix branch for this HEAD_REF using the Fix Branch Prefix from Context. Create it if missing, update it otherwise, and push changes to origin.
   - Attempt to resolve the CI failure with minimal, targeted edits consistent with the repo's style.
   - Do NOT create a PR. Instead, post or update a single natural-language PR comment (1–2 sentences) that briefly explains the fix and includes an inline compare link to quick-create a PR.
3) If NOT tied to a PR:
   - Treat the TARGET default branch as the failing base. Create a fix branch from the TARGET default branch using the Fix Branch Prefix and the run id for uniqueness.
   - Attempt to resolve the CI failure with minimal, targeted edits consistent with the repo's style.
   - If and only if you made a safe, actionable fix: push the fix branch and create a PR back into the default branch with a concise title/body.
4) If no actionable fix is possible, make no changes and post no comment / create no PR.

# Inputs and conventions:
- Use `gh api`, `gh run view`, `gh pr view`, `gh pr diff`, `gh pr list`, `gh run download`, and git commands as needed.
- NEVER run `gh run view` without a run id argument (use the run id from Context).
- NEVER put `--repo ...` on its own line; it must be part of the same `gh ...` command.
- For ANY `gh` command, always target the intended repo explicitly:
  - Run/workflow metadata MUST target RUN_REPOSITORY:
    - Prefer explicit REST endpoints like `gh api repos/$RUN_REPOSITORY/actions/runs/$GH_RUN_ID`
    - Or pass `--repo "$RUN_REPOSITORY"` (e.g. `gh run view "$GH_RUN_ID" --repo "$RUN_REPOSITORY"`)
  - Target-repo PR creation MUST target TARGET_REPOSITORY:
    - Pass `--repo "$TARGET_REPOSITORY"` for `gh pr create`, `gh pr view`, etc.
- Never run `gh pr create` without an explicit `--repo` flag.
- When pushing commits / creating PRs, operate on TARGET_REPOSITORY (your current working directory is the target repo checkout).
- Avoid duplicate comments; if a previous bot comment exists, update it instead of posting a new one.

# Deliverables when updates occur:
- If PR-associated: pushed commits to the persistent fix branch for the PR head, and a single PR comment with a quick-create compare link.
- If not PR-associated: a PR opened from the fix branch into the default branch.
EOF
)"

PROMPT="${PROMPT//__RUN_REPOSITORY_VALUE__/${RUN_REPOSITORY}}"
PROMPT="${PROMPT//__GH_RUN_ID_VALUE__/${GH_RUN_ID:-}}"
PROMPT="${PROMPT//__GH_RUN_URL_VALUE__/${GH_RUN_URL:-}}"
PROMPT="${PROMPT//__PR_NUMBER_VALUE__/${PR_NUMBER:-}}"
PROMPT="${PROMPT//__TARGET_REPOSITORY_VALUE__/${TARGET_REPOSITORY}}"
PROMPT="${PROMPT//__TARGET_OWNER_VALUE__/${TARGET_OWNER}}"
PROMPT="${PROMPT//__TARGET_REPO_VALUE__/${TARGET_REPO}}"
PROMPT="${PROMPT//__TARGET_DEFAULT_BRANCH_VALUE__/${TARGET_DEFAULT_BRANCH}}"
PROMPT="${PROMPT//__BRANCH_PREFIX_VALUE__/${BRANCH_PREFIX}}"

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
    OUTPUT="$(CURSOR_AGENT_AUTOMATION=true cursor-agent -p "$PROMPT" --force --model "$MODEL" --output-format=text 2>&1)"
    EXIT_CODE=$?
    set -e

    echo "$OUTPUT"

    if [[ $EXIT_CODE -eq 0 ]]; then
        break
    fi

    if echo "$OUTPUT" | grep -q "ConnectError: \\[unavailable\\]" && [[ $attempt -lt $max_attempts ]]; then
        echo "cursor-agent connection unavailable; retrying in ${sleep_seconds}s..."
        sleep "$sleep_seconds"
        attempt=$((attempt + 1))
        sleep_seconds=$((sleep_seconds * 2))
        continue
    fi

    exit "$EXIT_CODE"
done
