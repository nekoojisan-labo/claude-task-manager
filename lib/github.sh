#!/usr/bin/env bash
# lib/github.sh — GitHub API helpers
# Requires: GITHUB_TOKEN, GITHUB_OWNER, GITHUB_REPO (set in .env or exported)
# Usage: source lib/github.sh

set -euo pipefail

GITHUB_API="https://api.github.com"

# github_get_file <path>
# Prints raw file content to stdout. Sets GITHUB_FILE_SHA in caller scope.
github_get_file() {
  local file_path="$1"
  local response
  response=$(curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "${GITHUB_API}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${file_path}")

  GITHUB_FILE_SHA=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")
  echo "$response" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
print(base64.b64decode(data['content'].replace('\n','')).decode('utf-8'))
"
}

# github_update_file <path> <content> <sha> <commit_message>
# Writes content to the given file path, using sha for conflict detection.
github_update_file() {
  local file_path="$1"
  local content="$2"
  local sha="$3"
  local message="${4:-"chore: update ${file_path}"}"

  local encoded
  encoded=$(echo "$content" | base64)

  curl -sf -X PUT \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Type: application/json" \
    "${GITHUB_API}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${file_path}" \
    -d "{
      \"message\": \"${message}\",
      \"content\": \"${encoded}\",
      \"sha\": \"${sha}\"
    }" > /dev/null
}

# github_raw_get <path>
# Fetches raw file content without SHA tracking (used for status.json polling).
github_raw_get() {
  local file_path="$1"
  curl -sf \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "${GITHUB_API}/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${file_path}"
}
