#!/usr/bin/env bash
# task-runner.sh — Claude Task Manager execution loop
# Runs every 15 minutes via launchd. Picks up pending tasks and executes them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
LOG_DIR="${SCRIPT_DIR}/logs"
ENV_FILE="${SCRIPT_DIR}/.env"

# Load env
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  set -a; source "${ENV_FILE}"; set +a
fi

# Validate required env vars
for var in GITHUB_TOKEN GITHUB_OWNER GITHUB_REPO CLAUDE_BIN; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] Required env var not set: ${var}" >&2
    exit 1
  fi
done

# Source helpers
# shellcheck source=lib/github.sh
source "${LIB_DIR}/github.sh"

# Setup logging
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/$(date +%Y-%m-%d).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() {
  local task_id="$1"; shift
  log "$*"
  _update_status_log "${task_id}" "$*"
}

# ── Status helpers ──────────────────────────────────────────────────────────

_set_status_running() {
  local task_id="$1" task_title="$2" agent="$3" step="$4"
  local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local content
  content=$(python3 -c "
import json, sys
print(json.dumps({
  'running': True,
  'task_id': sys.argv[1],
  'task_title': sys.argv[2],
  'agent': sys.argv[3],
  'step': sys.argv[4],
  'started_at': sys.argv[5],
  'log': [],
  'updated_at': sys.argv[5],
  'last_completed_at': None,
  'last_task_id': None,
  'last_status': None
}, ensure_ascii=False, indent=2))
" "$task_id" "$task_title" "$agent" "$step" "$now")

  local sha
  github_get_file "status.json" > /dev/null
  sha="${GITHUB_FILE_SHA}"
  github_update_file "status.json" "$content" "$sha" "chore: task ${task_id} started"
}

_update_status_log() {
  local task_id="$1"; shift
  local message="[$(date '+%H:%M:%S')] $*"
  local current_content sha
  current_content=$(github_get_file "status.json")
  sha="${GITHUB_FILE_SHA}"
  local new_content
  new_content=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
if data.get('task_id') == sys.argv[2]:
  data.setdefault('log', []).append(sys.argv[3])
  data['updated_at'] = sys.argv[4]
print(json.dumps(data, ensure_ascii=False, indent=2))
" "$current_content" "$task_id" "$message" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")")
  github_update_file "status.json" "$new_content" "$sha" "chore: log update"
}

_set_status_idle() {
  local task_id="$1" final_status="$2"
  local now; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local current_content sha
  current_content=$(github_get_file "status.json")
  sha="${GITHUB_FILE_SHA}"
  local new_content
  new_content=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
data['running'] = False
data['task_id'] = None
data['task_title'] = None
data['agent'] = None
data['step'] = None
data['started_at'] = None
data['last_completed_at'] = sys.argv[3]
data['last_task_id'] = sys.argv[2]
data['last_status'] = sys.argv[4]
data['updated_at'] = sys.argv[3]
print(json.dumps(data, ensure_ascii=False, indent=2))
" "$current_content" "$task_id" "$now" "$final_status")
  github_update_file "status.json" "$new_content" "$sha" "chore: task ${task_id} ${final_status}"
}

# ── Task helpers ─────────────────────────────────────────────────────────────

_get_pending_task() {
  local tasks_json="$1"
  python3 -c "
import json, sys
data = json.loads(sys.argv[1])
pending = [t for t in data.get('tasks', []) if t['status'] == 'pending']
if pending:
  print(json.dumps(pending[0]))
" "$tasks_json"
}

_update_task_field() {
  local tasks_json="$1" task_id="$2" field="$3" value="$4"
  python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for t in data['tasks']:
  if t['id'] == sys.argv[2]:
    t[sys.argv[3]] = json.loads(sys.argv[4])
    import datetime
    t['updated_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps(data, ensure_ascii=False, indent=2))
" "$tasks_json" "$task_id" "$field" "$value"
}

_update_task_multi() {
  # Usage: _update_task_multi <tasks_json> <task_id> <key=json_value> [<key=json_value> ...]
  local tasks_json="$1" task_id="$2"
  shift 2
  local updates=("$@")
  python3 - "$tasks_json" "$task_id" "${updates[@]}" <<'PYEOF'
import json, sys, datetime
data = json.loads(sys.argv[1])
task_id = sys.argv[2]
for t in data['tasks']:
  if t['id'] == task_id:
    for kv in sys.argv[3:]:
      k, v = kv.split('=', 1)
      t[k] = json.loads(v)
    t['updated_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps(data, ensure_ascii=False, indent=2))
PYEOF
}

_get_skills_list() {
  local agents_dir="${HOME}/.claude/agents"
  if [[ -d "$agents_dir" ]]; then
    ls "$agents_dir" 2>/dev/null | sed 's/\.md$//' | tr '\n' ' '
  else
    echo "none"
  fi
}

# ── Main loop ────────────────────────────────────────────────────────────────

main() {
  log "=== Task Runner start ==="

  # 1. Fetch tasks.json
  local tasks_content sha
  tasks_content=$(github_get_file "tasks.json")
  sha="${GITHUB_FILE_SHA}"

  # 2. Find first pending task
  local task_json
  task_json=$(_get_pending_task "$tasks_content")
  if [[ -z "$task_json" ]]; then
    log "No pending tasks."
    exit 0
  fi

  # Extract task fields
  local task_id title description task_type approval_required
  task_id=$(echo "$task_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['id'])")
  title=$(echo "$task_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['title'])")
  description=$(echo "$task_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('description',''))")
  task_type=$(echo "$task_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('type','other'))")
  approval_required=$(echo "$task_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('approval_required', False))")

  log "Processing task: ${task_id} — ${title}"

  # 3. Mark as analyzing
  _set_status_running "$task_id" "$title" "analyzer" "Analyzing task with Claude Code"
  tasks_content=$(_update_task_field "$tasks_content" "$task_id" "status" '"analyzing"')
  github_update_file "tasks.json" "$tasks_content" "$sha" "chore: task ${task_id} analyzing"
  sha="${GITHUB_FILE_SHA}"

  # 4. Run Claude analysis
  log_step "$task_id" "Running skill analysis..."
  local skills_list
  skills_list=$(_get_skills_list)
  local analyze_prompt
  analyze_prompt=$(python3 - "${LIB_DIR}/analyze-prompt.txt" "$title" "$description" "$task_type" "$skills_list" <<'PYEOF'
import sys
with open(sys.argv[1]) as f:
    tmpl = f.read()
result = (tmpl
    .replace('{{TITLE}}',       sys.argv[2])
    .replace('{{DESCRIPTION}}', sys.argv[3])
    .replace('{{TYPE}}',        sys.argv[4])
    .replace('{{SKILLS_LIST}}', sys.argv[5]))
print(result, end='')
PYEOF
)

  local analysis_json
  analysis_json=$("${CLAUDE_BIN}" -p "$analyze_prompt" --model haiku 2>/dev/null | \
    python3 -c "import sys; data=sys.stdin.read(); start=data.find('{'); end=data.rfind('}')+1; print(data[start:end])")

  if [[ -z "$analysis_json" ]]; then
    log "ERROR: Claude analysis returned empty result"
    tasks_content=$(_update_task_field "$tasks_content" "$task_id" "status" '"failed"')
    tasks_content=$(_update_task_field "$tasks_content" "$task_id" "result" '"Analysis failed: empty response"')
    github_update_file "tasks.json" "$tasks_content" "$sha" "chore: task ${task_id} failed"
    _set_status_idle "$task_id" "failed"
    exit 1
  fi

  log_step "$task_id" "Analysis complete: ${analysis_json:0:120}..."

  # Extract analysis results
  local risk_level skill_match skill_status execution_prompt
  risk_level=$(echo "$analysis_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['risk_level'])")
  skill_match=$(echo "$analysis_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('skill_match') or '')")
  skill_status=$(echo "$analysis_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['skill_status'])")
  execution_prompt=$(echo "$analysis_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['execution_prompt'])")

  # 5. Update task with analysis
  tasks_content=$(_update_task_multi "$tasks_content" "$task_id" \
    "risk_level=\"${risk_level}\"" \
    "skill_match=$(echo "$analysis_json" | python3 -c "import sys,json; v=json.loads(sys.stdin.read()).get('skill_match'); print(json.dumps(v))")" \
    "skill_status=\"${skill_status}\"")

  # 6. Approval logic
  local needs_approval=false
  if [[ "$risk_level" == "high" ]]; then
    needs_approval=true
    log_step "$task_id" "HIGH risk — requesting Telegram approval"
  elif [[ "$approval_required" == "True" && "$risk_level" == "medium" ]]; then
    needs_approval=true
    log_step "$task_id" "MEDIUM risk + approval_required — requesting Telegram approval"
  fi

  if [[ "$needs_approval" == "true" ]]; then
    tasks_content=$(_update_task_field "$tasks_content" "$task_id" "status" '"waiting_approval"')
    github_update_file "tasks.json" "$tasks_content" "$sha" "chore: task ${task_id} waiting_approval"
    _set_status_idle "$task_id" "waiting_approval"
    log "Task ${task_id} queued for Telegram approval."
    # Telegram notification is sent by bot.py polling tasks with waiting_approval status
    exit 0
  fi

  # 7. Execute
  log_step "$task_id" "Executing with Claude Code (skill: ${skill_match:-none})"
  _set_status_running "$task_id" "$title" "${skill_match:-claude}" "Executing: ${execution_prompt:0:80}..."
  tasks_content=$(github_get_file "tasks.json")
  sha="${GITHUB_FILE_SHA}"
  tasks_content=$(_update_task_field "$tasks_content" "$task_id" "status" '"running"')
  github_update_file "tasks.json" "$tasks_content" "$sha" "chore: task ${task_id} running"
  sha="${GITHUB_FILE_SHA}"

  local exec_result
  if ! exec_result=$("${CLAUDE_BIN}" -p "$execution_prompt" --model sonnet --dangerously-skip-permissions 2>&1); then
    log_step "$task_id" "Execution failed: ${exec_result:0:200}"
    tasks_content=$(_update_task_multi "$tasks_content" "$task_id" \
      "status=\"failed\"" \
      "result=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1][:500]))" "$exec_result")")
    github_update_file "tasks.json" "$tasks_content" "$sha" "chore: task ${task_id} failed"
    _set_status_idle "$task_id" "failed"
    exit 1
  fi

  # 8. Mark completed
  log_step "$task_id" "Completed successfully"
  local executed_at
  executed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tasks_content=$(_update_task_multi "$tasks_content" "$task_id" \
    "status=\"completed\"" \
    "executed_at=\"${executed_at}\"" \
    "result=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1][:1000]))" "$exec_result")")
  github_update_file "tasks.json" "$tasks_content" "$sha" "feat: task ${task_id} completed"
  _set_status_idle "$task_id" "completed"
  log "=== Task Runner done ==="
}

main "$@"
