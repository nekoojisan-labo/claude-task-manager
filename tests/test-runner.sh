#!/usr/bin/env bash
# tests/test-runner.sh — Smoke tests for task-runner system

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/.env" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/github.sh"

PASS=0; FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: ${label}"; ((PASS++))
  else
    echo "  FAIL: ${label} — expected='${expected}' got='${actual}'"; ((FAIL++))
  fi
}

echo "=== Task Runner Integration Tests ==="

# Test 1: GitHub API read — tasks.json
echo "Test 1: GitHub API can read tasks.json"
content=$(github_get_file "tasks.json")
assert_eq "tasks.json has 'tasks' key" "True" \
  "$(echo "$content" | python3 -c "import sys,json; print('True' if 'tasks' in json.loads(sys.stdin.read()) else 'False')")"

# Test 2: GitHub API read — status.json
echo "Test 2: GitHub API can read status.json"
status=$(github_get_file "status.json")
assert_eq "status.json has 'running' key" "True" \
  "$(echo "$status" | python3 -c "import sys,json; print('True' if 'running' in json.loads(sys.stdin.read()) else 'False')")"

# Test 3: Task creation round-trip
echo "Test 3: Create a test task and verify it appears"
tasks_json=$(github_get_file "tasks.json")
sha="${GITHUB_FILE_SHA}"
test_task=$(python3 -c "
import json, datetime
now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps({
  'id': 'task_test_001',
  'title': 'Test Task — DELETE ME',
  'description': 'Smoke test',
  'type': 'other',
  'status': 'pending',
  'approval_required': False,
  'risk_level': None,
  'skill_match': None,
  'skill_status': None,
  'workflow_steps': [],
  'created_at': now,
  'updated_at': now,
  'executed_at': None,
  'result': None,
  'telegram_message_id': None
}))
")
new_content=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
task = json.loads(sys.argv[2])
data['tasks'].insert(0, task)
print(json.dumps(data, ensure_ascii=False, indent=2))
" "$tasks_json" "$test_task")
github_update_file "tasks.json" "$new_content" "$sha" "test: add smoke test task"
verify_content=$(github_get_file "tasks.json")
assert_eq "test task exists in tasks.json" "True" \
  "$(echo "$verify_content" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
print(str(any(t['id']=='task_test_001' for t in data['tasks'])))
")"

# Cleanup test task
cleanup_sha="${GITHUB_FILE_SHA}"
cleanup_content=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
data['tasks'] = [t for t in data['tasks'] if t['id'] != 'task_test_001']
print(json.dumps(data, ensure_ascii=False, indent=2))
" "$verify_content")
github_update_file "tasks.json" "$cleanup_content" "$cleanup_sha" "test: remove smoke test task"

# Test 4: task-runner.sh is executable
echo "Test 4: task-runner.sh is executable"
assert_eq "task-runner.sh is executable" "True" \
  "$([ -x "${SCRIPT_DIR}/task-runner.sh" ] && echo 'True' || echo 'False')"

# Test 5: lib/analyze-prompt.txt has required placeholders
echo "Test 5: analyze-prompt.txt has all required placeholders"
prompt_content=$(cat "${SCRIPT_DIR}/lib/analyze-prompt.txt")
for placeholder in "{{TITLE}}" "{{DESCRIPTION}}" "{{TYPE}}" "{{SKILLS_LIST}}"; do
  assert_eq "analyze-prompt.txt has ${placeholder}" "True" \
    "$(echo "$prompt_content" | grep -q "${placeholder}" && echo 'True' || echo 'False')"
done

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
