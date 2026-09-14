#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# protect-main.sh — apply the `main` branch protection, identical to
# hkm-kernel's (tools/ci/protect-main.sh there) except for the check names.
# Idempotent — safe to re-run. Needs `gh`, authenticated as a repo admin.
#
#   .github/scripts/protect-main.sh
#
#   - 1 approving review, from a CODE OWNER (.github/CODEOWNERS); stale
#     approvals dismissed when new commits are pushed
#   - required status checks, and the branch must be up to date with main
#   - enforced for admins too — no bypass
#   - linear history, conversations resolved before merge
#   - force-push and deletion blocked
#
# Unlike the kernel's script this does NOT rewrite CODEOWNERS: the file here
# already lists the same owners, and the kernel's version overwrites it with a
# single login.
#
# THE CHECK NAMES MUST MATCH ci.yml's JOB NAMES EXACTLY. With enforce_admins on,
# a required check that no job reports blocks every pull request forever and
# nobody can override it. Renaming a job in ci.yml means updating this list in
# the same change — and applying it only AFTER that change has merged.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner -q '.nameWithOwner')}"
BRANCH="main"

echo "Repo:   $REPO"
echo "Branch: $BRANCH"

gh api -X PUT "repos/$REPO/branches/$BRANCH/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - >/dev/null <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["test (ubuntu-latest)", "test (macos-latest)", "cross-compile"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
  "block_creations": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON

echo "Branch protection applied to $BRANCH."

# A code owner without write access is silently ignored by GitHub, which can
# leave a PR with no one able to approve it. Say so rather than find out then.
for owner in $(grep -Eo '@[A-Za-z0-9_-]+' .github/CODEOWNERS | tr -d '@' | sort -u); do
  perm="$(gh api "repos/$REPO/collaborators/$owner/permission" --jq .permission 2>/dev/null || echo none)"
  case "$perm" in
    admin|maintain|write) echo "  code owner @$owner: $perm" ;;
    *) echo "  code owner @$owner: $perm — CANNOT approve (needs write access)" ;;
  esac
done
