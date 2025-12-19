#!/bin/bash
set -euo pipefail

# Set variables from environment
OWNER="${GITHUB_REPOSITORY_OWNER:-}"
REPO="${GITHUB_REPOSITORY_NAME:-}"

# Extract repo name from GITHUB_REPOSITORY if GITHUB_REPOSITORY_NAME is not set
if [[ -z "${REPO}" ]] && [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    REPO="${GITHUB_REPOSITORY##*/}"
fi

# Extract owner from GITHUB_REPOSITORY if GITHUB_REPOSITORY_OWNER is not set
if [[ -z "${OWNER}" ]] && [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    OWNER="${GITHUB_REPOSITORY%%/*}"
fi

# Verify required variables are set
if [[ -z "${OWNER}" ]] || [[ -z "${REPO}" ]]; then
    echo "Error: GITHUB_REPOSITORY_OWNER and GITHUB_REPOSITORY_NAME must be set"
    exit 1
fi

# Get the last failed workflow run and extract ID and URL
RUN_INFO=$(gh api "repos/$OWNER/$REPO/actions/runs" -f status=completed -f per_page=100 --jq '
  .workflow_runs
  | map(select(.conclusion=="failure" or .conclusion=="timed_out"))
  | first
  | "\(.id) \(.html_url)"
')

# Parse the output to extract ID and URL
if [[ -n "${RUN_INFO}" ]]; then
    GITHUB_RUN_ID=$(echo "$RUN_INFO" | awk '{print $1}')
    GITHUB_RUN_URL=$(echo "$RUN_INFO" | awk '{print $2}')
else
    echo "Warning: No failed workflow runs found"
    GITHUB_RUN_ID=""
    GITHUB_RUN_URL=""
fi

cursor-agent -p "You are operating in a GitHub Actions runner.

The GitHub CLI is available as \`gh\` and authenticated via \`GH_TOKEN\`. Git is available. You have write access to repository contents and can comment on pull requests, but you must not create or edit PRs directly.

# Context:
- Repo: ${GITHUB_REPOSITORY}
- Owner: ${GITHUB_REPOSITORY_OWNER}
- Repo Name: ${GITHUB_REPOSITORY_NAME}
- Workflow Run ID: ${GITHUB_RUN_ID}
- Workflow Run URL: ${GITHUB_RUN_URL}
- Fix Branch Prefix: ${BRANCH_PREFIX}

# Goal:
- Implement an end-to-end CI fix flow driven by the failing PR, creating a separate persistent fix branch and proposing a quick-create PR back into the original PR's branch.

# Requirements:
1) Identify the PR associated with the failed workflow run and determine its base and head branches. Let HEAD_REF be the PR's head branch (the contributor/origin branch).
2) Maintain a persistent fix branch for this PR head using the Fix Branch Prefix from Context. Create it if missing, update it otherwise, and push changes to origin.
3) Attempt to resolve the CI failure by making minimal, targeted edits consistent with the repo's style. Keep changes scoped and safe.
4) You do NOT have permission to create PRs. Instead, post or update a single natural-language PR comment (1–2 sentences) that briefly explains the CI fix and includes an inline compare link to quick-create a PR.

# Inputs and conventions:
- Use `gh api`, `gh run view`, `gh pr view`, `gh pr diff`, `gh pr list`, `gh run download`, and git commands as needed to discover the failing PR and branches.
- Avoid duplicate comments; if a previous bot comment exists, update it instead of posting a new one.
- If no actionable fix is possible, make no changes and post no comment.

# Deliverables when updates occur:
- Pushed commits to the persistent fix branch for this PR head.
- A single natural-language PR comment on the original PR that includes the inline compare link above.
" --force --model "$MODEL" --output-format=text