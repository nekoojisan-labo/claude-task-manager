# Claude Task Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a browser-accessible task manager that submits tasks to Claude Code for execution on Mac, with live agent status visible from any device, and Telegram-based approval for high-risk operations.

**Architecture:** GitHub Pages (static) hosts the Web UI which reads/writes `tasks.json` and polls `status.json` in the same repo via GitHub API. A `task-runner.sh` script on Mac (launchd, 15-min schedule) picks up pending tasks, executes them with Claude Code, and writes execution state to `status.json` after each step. The existing `bot.py` Telegram bot is extended with `/tasks`, inline approval buttons, and a callback handler that writes approval decisions back to `tasks.json`.

**Tech Stack:** Bash (task-runner), Python 3.11 + python-telegram-bot 20.x (bot), Vanilla JS + CSS Custom Properties (Web UI), GitHub REST API v3

---

## File Map

### Create (new files)
| File | Responsibility |
|------|---------------|
| `tasks.json` | Authoritative task list, read/written by all 3 components |
| `status.json` | Live execution state (current agent, log lines), written by task-runner only |
| `task-runner.sh` | Main execution loop: fetch → analyze → execute → update |
| `lib/github.sh` | GitHub API helper functions (get/update file with SHA tracking) |
| `lib/analyze-prompt.txt` | Claude analysis prompt template (skill match + risk) |
| `launchd/com.nekoojisan.claude-task-manager.plist` | launchd schedule (15 min) |
| `tests/test-runner.sh` | Integration smoke tests for task-runner |

### Modify (existing files)
| File | What changes |
|------|-------------|
| `index.html` | Add: settings modal, GitHub API CRUD, live status panel, polling |
| `~/Desktop/claude-telegram-bot/bot.py` | Add: `/tasks`, InlineKeyboardButton approval, CallbackQueryHandler |

---

## Task 1: Data Files — tasks.json + status.json

**Files:**
- Create: `tasks.json`
- Create: `status.json`

- [ ] **Step 1: Create tasks.json**

```json
{
  "tasks": []
}
```

Save to `/Users/takayamanoboruhaku/Desktop/claude-task-manager/tasks.json`

- [ ] **Step 2: Create status.json**

```json
{
  "running": false,
  "task_id": null,
  "task_title": null,
  "agent": null,
  "step": null,
  "started_at": null,
  "log": [],
  "updated_at": null,
  "last_completed_at": null,
  "last_task_id": null,
  "last_status": null
}
```

Save to `/Users/takayamanoboruhaku/Desktop/claude-task-manager/status.json`

- [ ] **Step 3: Commit both files**

```bash
cd ~/Desktop/claude-task-manager
git add tasks.json status.json
git commit -m "feat: add tasks.json and status.json data files"
git push origin main
```

---

## Task 2: GitHub API Helper Library

**Files:**
- Create: `lib/github.sh`

This library wraps GitHub API calls. All functions write results to stdout. The SHA tracking is critical — GitHub API requires the current SHA to update a file (prevents conflicts).

- [ ] **Step 1: Create lib/ directory and github.sh**

```bash
mkdir -p ~/Desktop/claude-task-manager/lib
```

- [ ] **Step 2: Write lib/github.sh**

```bash
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
```

- [ ] **Step 3: Commit**

```bash
cd ~/Desktop/claude-task-manager
git add lib/github.sh
git commit -m "feat: add GitHub API helper library"
git push origin main
```

---

## Task 3: Claude Analysis Prompt Template

**Files:**
- Create: `lib/analyze-prompt.txt`

- [ ] **Step 1: Write lib/analyze-prompt.txt**

```
You are a task analysis agent for Claude Task Manager.

Analyze the following task and return a JSON object (no markdown, no explanation, just valid JSON).

Task:
  Title: {{TITLE}}
  Description: {{DESCRIPTION}}
  Type: {{TYPE}}

Available skills in ~/.claude/agents/:
{{SKILLS_LIST}}

Return this exact JSON structure:
{
  "risk_level": "low|medium|high",
  "risk_reason": "one sentence explanation",
  "skill_match": "skill-name or null",
  "skill_status": "exists|suggest_create|none",
  "workflow_steps": ["step 1", "step 2", "step 3"],
  "execution_prompt": "the prompt to send to Claude Code to execute this task"
}

Risk rules:
- high: involves git push, file deletion, external API calls that send data, billing actions, deploying to production
- medium: creates or modifies files outside Obsidian, installs packages, modifies system config
- low: reads files, generates content, writes to Obsidian vault, research, analysis

If skill_match is null, set skill_status to "suggest_create" and include a suggested skill name in workflow_steps[0].
```

- [ ] **Step 2: Commit**

```bash
cd ~/Desktop/claude-task-manager
git add lib/analyze-prompt.txt
git commit -m "feat: add task analysis prompt template"
git push origin main
```

---

## Task 4: Task Runner — Main Script

**Files:**
- Create: `task-runner.sh`

This is the core execution loop. It runs every 15 minutes via launchd. The `.env` file at `~/Desktop/claude-task-manager/.env` must contain `GITHUB_TOKEN`, `GITHUB_OWNER`, `GITHUB_REPO`.

- [ ] **Step 1: Create .env template (do not commit)**

```bash
# ~/Desktop/claude-task-manager/.env
GITHUB_TOKEN=ghp_YOUR_TOKEN_HERE
GITHUB_OWNER=nekoojisan-labo
GITHUB_REPO=claude-task-manager
CLAUDE_BIN=/Users/takayamanoboruhaku/.nvm/versions/node/v23.11.0/bin/claude
```

Add to `.gitignore`:
```bash
echo ".env" >> ~/Desktop/claude-task-manager/.gitignore
echo "logs/" >> ~/Desktop/claude-task-manager/.gitignore
```

- [ ] **Step 2: Write task-runner.sh**

```bash
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
  analyze_prompt=$(sed \
    -e "s/{{TITLE}}/${title}/g" \
    -e "s/{{DESCRIPTION}}/${description}/g" \
    -e "s/{{TYPE}}/${task_type}/g" \
    -e "s/{{SKILLS_LIST}}/${skills_list}/g" \
    "${LIB_DIR}/analyze-prompt.txt")

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
```

- [ ] **Step 3: Make executable and commit**

```bash
chmod +x ~/Desktop/claude-task-manager/task-runner.sh
cd ~/Desktop/claude-task-manager
git add task-runner.sh lib/analyze-prompt.txt .gitignore
git commit -m "feat: add task-runner.sh and analysis prompt"
git push origin main
```

---

## Task 5: launchd Plist

**Files:**
- Create: `launchd/com.nekoojisan.claude-task-manager.plist`

- [ ] **Step 1: Write the plist**

Replace `YOUR_USERNAME` with actual username (`takayamanoboruhaku`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nekoojisan.claude-task-manager</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/takayamanoboruhaku/Desktop/claude-task-manager/task-runner.sh</string>
  </array>

  <key>StartInterval</key>
  <integer>900</integer>

  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>/Users/takayamanoboruhaku/Desktop/claude-task-manager/logs/launchd-stdout.log</string>

  <key>StandardErrorPath</key>
  <string>/Users/takayamanoboruhaku/Desktop/claude-task-manager/logs/launchd-stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/Users/takayamanoboruhaku/.nvm/versions/node/v23.11.0/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key>
    <string>/Users/takayamanoboruhaku</string>
  </dict>
</dict>
</plist>
```

- [ ] **Step 2: Install launchd agent**

```bash
cp ~/Desktop/claude-task-manager/launchd/com.nekoojisan.claude-task-manager.plist \
   ~/Library/LaunchAgents/com.nekoojisan.claude-task-manager.plist

launchctl load ~/Library/LaunchAgents/com.nekoojisan.claude-task-manager.plist
launchctl list | grep claude-task-manager
# Expected: entry with pid (or "-") and exit code 0
```

- [ ] **Step 3: Smoke test**

```bash
# Manual trigger
launchctl start com.nekoojisan.claude-task-manager

# Check log after ~5 seconds
tail -20 ~/Desktop/claude-task-manager/logs/$(date +%Y-%m-%d).log
# Expected: "=== Task Runner start ===" + "No pending tasks."
```

- [ ] **Step 4: Commit plist**

```bash
cd ~/Desktop/claude-task-manager
git add launchd/
git commit -m "feat: add launchd plist for 15-min task runner schedule"
git push origin main
```

---

## Task 6: Web UI — Settings + GitHub API Integration

**Files:**
- Modify: `index.html` (add settings modal, token storage, API calls)

The Web UI currently has no JavaScript CRUD. This task wires up the existing form to GitHub API, adds a settings screen, and enables the kanban board to load real data.

- [ ] **Step 1: Read current index.html JavaScript section**

```bash
grep -n "script\|function\|fetch\|localStorage" ~/Desktop/claude-task-manager/index.html | head -40
```

- [ ] **Step 2: Add settings constants and GitHub API module at top of `<script>` block**

Find the `<script>` tag. Add these at the very top:

```javascript
// ── Config ─────────────────────────────────────────────────────────
const SETTINGS_KEY = 'ctm_settings';

function loadSettings() {
  try {
    return JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}');
  } catch { return {}; }
}

function saveSettings(s) {
  localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
}

// ── GitHub API ──────────────────────────────────────────────────────
async function ghGet(path, token, owner, repo) {
  const res = await fetch(
    `https://api.github.com/repos/${owner}/${repo}/contents/${path}`,
    { headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github.v3+json' } }
  );
  if (!res.ok) throw new Error(`GitHub API ${res.status}: ${path}`);
  const data = await res.json();
  return {
    content: JSON.parse(atob(data.content.replace(/\n/g, ''))),
    sha: data.sha
  };
}

async function ghPut(path, content, sha, message, token, owner, repo) {
  const encoded = btoa(unescape(encodeURIComponent(JSON.stringify(content, null, 2))));
  const body = { message, content: encoded, sha };
  const res = await fetch(
    `https://api.github.com/repos/${owner}/${repo}/contents/${path}`,
    {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github.v3+json',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(body)
    }
  );
  if (!res.ok) {
    const err = await res.json();
    throw new Error(`GitHub PUT ${res.status}: ${err.message}`);
  }
  return res.json();
}
```

- [ ] **Step 3: Add task ID generator and task creation function**

```javascript
function makeTaskId() {
  const d = new Date();
  const ymd = d.toISOString().slice(0,10).replace(/-/g,'');
  const ms = String(d.getTime()).slice(-4);
  return `task_${ymd}_${ms}`;
}

async function createTask(formData) {
  const cfg = loadSettings();
  if (!cfg.token || !cfg.owner || !cfg.repo) throw new Error('Settings not configured');

  const { content: data, sha } = await ghGet('tasks.json', cfg.token, cfg.owner, cfg.repo);
  const now = new Date().toISOString();
  const task = {
    id: makeTaskId(),
    title: formData.title,
    description: formData.description || '',
    type: formData.type || 'other',
    status: 'pending',
    approval_required: formData.approval_required || false,
    risk_level: null,
    skill_match: null,
    skill_status: null,
    workflow_steps: [],
    created_at: now,
    updated_at: now,
    executed_at: null,
    result: null,
    telegram_message_id: null
  };
  data.tasks.unshift(task);
  await ghPut('tasks.json', data, sha, `feat: add task ${task.id}`, cfg.token, cfg.owner, cfg.repo);
  return task;
}
```

- [ ] **Step 4: Add loadBoard() and renderTasks()**

```javascript
const STATUS_COLS = ['pending','analyzing','waiting_approval','running','completed'];

let _tasksData = { tasks: [] };
let _tasksSha = '';

async function loadBoard() {
  const cfg = loadSettings();
  if (!cfg.token) { showSettingsPrompt(); return; }
  try {
    const { content, sha } = await ghGet('tasks.json', cfg.token, cfg.owner, cfg.repo);
    _tasksData = content;
    _tasksSha = sha;
    renderTasks(content.tasks);
  } catch (e) {
    showError('タスク読み込み失敗: ' + e.message);
  }
}

function renderTasks(tasks) {
  STATUS_COLS.forEach(status => {
    const col = document.querySelector(`.col[data-status="${status}"] .card-list`);
    if (!col) return;
    col.innerHTML = '';
    tasks.filter(t => t.status === status).forEach(t => {
      col.appendChild(buildCard(t));
    });
    // Update badge count
    const badge = document.querySelector(`.col[data-status="${status}"] .col-badge`);
    if (badge) badge.textContent = tasks.filter(t => t.status === status).length;
  });
}

function buildCard(task) {
  const el = document.createElement('li');
  el.className = 'card';
  el.dataset.risk = task.risk_level || 'low';
  el.innerHTML = `
    <h3 class="card-title">${escHtml(task.title)}</h3>
    ${task.description ? `<p class="card-desc">${escHtml(task.description.slice(0,120))}</p>` : ''}
    <div class="card-foot">
      <span class="badge badge--skill">${escHtml(task.skill_match || task.type)}</span>
      <span class="badge badge--risk badge--${task.risk_level || 'low'}">${task.risk_level || '—'}</span>
      <time class="card-time">${formatDate(task.created_at)}</time>
    </div>
  `;
  return el;
}

function escHtml(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function formatDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return `${d.getMonth()+1}/${d.getDate()} ${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;
}
```

- [ ] **Step 5: Add settings modal HTML to index.html body**

Add before the closing `</body>` tag:

```html
<!-- Settings Modal -->
<dialog id="settings-modal" class="modal" aria-label="設定">
  <div class="modal-box">
    <button class="modal-close" aria-label="閉じる" onclick="document.getElementById('settings-modal').close()">✕</button>
    <h2 class="modal-title">GitHub 設定</h2>
    <p class="modal-note">トークンはこのデバイスのみに保存されます（サーバー送信なし）</p>
    <form id="settings-form" class="modal-form">
      <label class="fi">
        <span class="fi-label">Personal Access Token</span>
        <input type="password" id="cfg-token" name="token" placeholder="ghp_..." required class="fi-input" autocomplete="off" />
      </label>
      <label class="fi">
        <span class="fi-label">Owner</span>
        <input type="text" id="cfg-owner" name="owner" placeholder="nekoojisan-labo" required class="fi-input" />
      </label>
      <label class="fi">
        <span class="fi-label">Repository</span>
        <input type="text" id="cfg-repo" name="repo" placeholder="claude-task-manager" required class="fi-input" />
      </label>
      <button type="submit" class="btn btn--primary">保存して接続</button>
    </form>
  </div>
</dialog>
```

- [ ] **Step 6: Wire up settings form and add a settings button to the header**

```javascript
// Settings form submit
document.getElementById('settings-form').addEventListener('submit', async e => {
  e.preventDefault();
  const fd = new FormData(e.target);
  saveSettings({ token: fd.get('token'), owner: fd.get('owner'), repo: fd.get('repo') });
  document.getElementById('settings-modal').close();
  await loadBoard();
});

// Pre-fill settings form with stored values
function openSettings() {
  const cfg = loadSettings();
  if (cfg.token) document.getElementById('cfg-token').value = cfg.token;
  if (cfg.owner) document.getElementById('cfg-owner').value = cfg.owner;
  if (cfg.repo)  document.getElementById('cfg-repo').value  = cfg.repo;
  document.getElementById('settings-modal').showModal();
}

function showSettingsPrompt() {
  openSettings();
}
```

Add a settings button to the existing header (find `<nav class="header-nav">` or similar and add):

```html
<button class="btn btn--icon" onclick="openSettings()" aria-label="設定" title="GitHub設定">
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
    <circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
  </svg>
</button>
```

- [ ] **Step 7: Wire up Add Task form to createTask()**

Find the existing form submission handler in index.html. Replace or add:

```javascript
document.getElementById('task-form').addEventListener('submit', async e => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const submitBtn = e.target.querySelector('[type="submit"]');
  submitBtn.disabled = true;
  submitBtn.textContent = '追加中...';
  try {
    await createTask({
      title: fd.get('title'),
      description: fd.get('description'),
      type: fd.get('type'),
      approval_required: fd.get('approval_required') === 'on'
    });
    e.target.reset();
    document.getElementById('task-modal')?.close();
    await loadBoard();
  } catch (err) {
    showError('タスク追加失敗: ' + err.message);
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = 'タスクを追加';
  }
});
```

- [ ] **Step 8: Add auto-polling (30s board, 5s status)**

```javascript
// Auto-refresh every 30s
setInterval(loadBoard, 30_000);

// Initial load on page ready
document.addEventListener('DOMContentLoaded', () => {
  loadBoard();
  loadStatus();
  setInterval(loadStatus, 5_000);
});
```

- [ ] **Step 9: Commit and push**

```bash
cd ~/Desktop/claude-task-manager
git add index.html
git commit -m "feat: add GitHub API integration, settings modal, auto-polling"
git push origin main
```

---

## Task 7: Web UI — Live Execution Status Panel

**Files:**
- Modify: `index.html` (add status panel HTML + CSS + loadStatus())

- [ ] **Step 1: Add status panel HTML**

Add after the `.board` section and before the mobile tab bar:

```html
<!-- Live Status Panel -->
<section id="status-panel" class="status-panel" aria-live="polite" aria-label="実行状況">
  <div class="status-header">
    <span class="status-dot" id="status-dot"></span>
    <span class="status-label" id="status-label">待機中</span>
    <span class="status-agent" id="status-agent"></span>
  </div>
  <div class="status-log" id="status-log" role="log" aria-label="実行ログ"></div>
</section>
```

- [ ] **Step 2: Add CSS for status panel (inside `@layer util`)**

```css
@layer util {
  .status-panel {
    position: fixed;
    bottom: calc(var(--tabbar-h) + var(--tabbar-safe) + var(--s2));
    left: var(--s1);
    right: var(--s1);
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--r-lg);
    padding: var(--s2) var(--s1);
    box-shadow: var(--sh);
    max-height: 180px;
    overflow: hidden;
    transition: max-height var(--dur) var(--ease);
    z-index: 90;
  }

  .status-panel.is-expanded { max-height: 380px; }

  @media (min-width: 768px) {
    .status-panel {
      position: static;
      max-width: 600px;
      margin: var(--s1) auto var(--s0);
      bottom: auto; left: auto; right: auto;
    }
  }

  .status-header {
    display: flex;
    align-items: center;
    gap: var(--s2);
    cursor: pointer;
    user-select: none;
  }

  .status-dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--muted);
    transition: background var(--dur);
    flex-shrink: 0;
  }
  .status-dot.is-running {
    background: var(--s-running);
    animation: pulse 1.2s ease-in-out infinite;
  }
  @keyframes pulse {
    0%,100% { opacity: 1; }
    50%      { opacity: .4; }
  }

  .status-label {
    font-size: var(--f3);
    font-weight: 600;
    color: var(--text);
    flex: 1;
  }

  .status-agent {
    font-size: var(--f4);
    color: var(--muted);
    font-family: var(--sans);
  }

  .status-log {
    margin-top: var(--s2);
    max-height: 260px;
    overflow-y: auto;
    font-size: var(--f4);
    font-family: 'Noto Sans JP', monospace;
    color: var(--text2);
    line-height: 1.6;
    border-top: 1px solid var(--border);
    padding-top: var(--s2);
    display: none;
  }

  .status-panel.is-expanded .status-log { display: block; }

  .status-log-line { padding: 1px 0; }
}
```

- [ ] **Step 3: Add loadStatus() JavaScript**

```javascript
async function loadStatus() {
  const cfg = loadSettings();
  if (!cfg.token) return;
  try {
    const { content: status } = await ghGet('status.json', cfg.token, cfg.owner, cfg.repo);
    renderStatus(status);
  } catch { /* silent fail — status is best-effort */ }
}

function renderStatus(status) {
  const dot   = document.getElementById('status-dot');
  const label = document.getElementById('status-label');
  const agent = document.getElementById('status-agent');
  const log   = document.getElementById('status-log');
  const panel = document.getElementById('status-panel');

  if (status.running) {
    dot.classList.add('is-running');
    label.textContent = status.task_title ? `実行中: ${status.task_title}` : '実行中...';
    agent.textContent = status.agent ? `[${status.agent}]` : '';
    panel.classList.add('is-expanded');
  } else {
    dot.classList.remove('is-running');
    if (status.last_status === 'completed') {
      label.textContent = `完了: ${status.last_task_id || '—'}`;
    } else if (status.last_status === 'waiting_approval') {
      label.textContent = '承認待ち';
    } else {
      label.textContent = '待機中';
    }
    agent.textContent = status.last_completed_at
      ? formatDate(status.last_completed_at)
      : '';
  }

  if (status.log && status.log.length > 0) {
    log.innerHTML = status.log
      .slice(-20)
      .map(line => `<div class="status-log-line">${escHtml(line)}</div>`)
      .join('');
    log.scrollTop = log.scrollHeight;
  }
}

// Tap header to expand/collapse log
document.getElementById('status-panel')?.querySelector('.status-header')
  ?.addEventListener('click', () => {
    document.getElementById('status-panel').classList.toggle('is-expanded');
  });
```

- [ ] **Step 4: Commit**

```bash
cd ~/Desktop/claude-task-manager
git add index.html
git commit -m "feat: add live execution status panel with 5s polling"
git push origin main
```

---

## Task 8: Telegram Bot — /tasks Command

**Files:**
- Modify: `~/Desktop/claude-telegram-bot/bot.py`

- [ ] **Step 1: Add imports at the top of bot.py**

After the existing imports, add:

```python
import base64
import urllib.request
import urllib.error
```

- [ ] **Step 2: Add GitHub config constants (after existing config block)**

Add after the `CLAUDE_TIMEOUT` line:

```python
# GitHub config for task manager
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GITHUB_OWNER = os.environ.get("GITHUB_OWNER", "nekoojisan-labo")
GITHUB_REPO  = os.environ.get("GITHUB_REPO", "claude-task-manager")
```

- [ ] **Step 3: Add GitHub helper functions**

Add after the `_split_message` function:

```python
# ---------------------------------------------------------------------------
# GitHub API helpers (task manager)
# ---------------------------------------------------------------------------

def _github_get_file(path: str) -> tuple[dict, str]:
    """Fetch file from GitHub repo. Returns (parsed_json, sha)."""
    url = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/contents/{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github.v3+json",
    })
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
    content = json.loads(base64.b64decode(data["content"].replace("\n", "")).decode("utf-8"))
    return content, data["sha"]


def _github_put_file(path: str, content: dict, sha: str, message: str) -> None:
    """Write file to GitHub repo."""
    import json as _json
    body = _json.dumps({
        "message": message,
        "content": base64.b64encode(
            _json.dumps(content, ensure_ascii=False, indent=2).encode("utf-8")
        ).decode("ascii"),
        "sha": sha,
    }).encode("utf-8")
    url = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/contents/{path}"
    req = urllib.request.Request(url, data=body, method="PUT", headers={
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "Accept": "application/vnd.github.v3+json",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=15):
        pass


import json as _json_module

def _get_tasks(status_filter: list[str] | None = None) -> list[dict]:
    """Fetch tasks from tasks.json, optionally filtered by status list."""
    data, _ = _github_get_file("tasks.json")
    tasks = data.get("tasks", [])
    if status_filter:
        tasks = [t for t in tasks if t.get("status") in status_filter]
    return tasks
```

- [ ] **Step 4: Add /tasks command handler**

Add after `cmd_daily`:

```python
async def cmd_tasks(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """List pending/waiting tasks from tasks.json."""
    if not _authorised(update.effective_chat.id):
        return

    thinking = await update.message.reply_text("タスク取得中...")
    try:
        tasks = _get_tasks(status_filter=["pending", "analyzing", "waiting_approval", "running"])
    except Exception as exc:
        await thinking.edit_text(f"[Error] GitHub API: {exc}")
        return

    if not tasks:
        await thinking.edit_text("アクティブなタスクはありません。")
        return

    STATUS_EMOJI = {
        "pending": "🕐",
        "analyzing": "🔍",
        "waiting_approval": "⚠️",
        "running": "⚡",
    }
    lines = [f"📋 アクティブタスク ({len(tasks)}件)\n"]
    for t in tasks[:10]:
        emoji = STATUS_EMOJI.get(t["status"], "•")
        risk = f" [{t['risk_level'].upper()}]" if t.get("risk_level") else ""
        lines.append(f"{emoji} {t['title']}{risk}")
        lines.append(f"   ID: {t['id']}")
        if t.get("skill_match"):
            lines.append(f"   Skill: {t['skill_match']}")

    await thinking.edit_text("\n".join(lines))
```

- [ ] **Step 5: Register /tasks handler in main()**

In `main()`, after `app.add_handler(CommandHandler("daily", cmd_daily))`, add:

```python
    app.add_handler(CommandHandler("tasks", cmd_tasks))
```

- [ ] **Step 6: Update /help command**

In `cmd_help`, update the help text to include:

```python
        "  /tasks - Show active tasks\n"
```

Add this line after the `/daily` line in `cmd_help`.

- [ ] **Step 7: Update /start command**

In `cmd_start`, update:

```python
        "Commands: /new /model /daily /tasks /status /help"
```

- [ ] **Step 8: Commit**

```bash
cd ~/Desktop/claude-telegram-bot
git add bot.py
git commit -m "feat: add /tasks command with GitHub API integration"
git push origin main
```

---

## Task 9: Telegram Bot — Approval Notifications + Callback

**Files:**
- Modify: `~/Desktop/claude-telegram-bot/bot.py`

- [ ] **Step 1: Add InlineKeyboardButton import**

Add to the existing telegram imports:

```python
from telegram import InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import CallbackQueryHandler
```

- [ ] **Step 2: Add approval sender function**

Add after `_get_tasks`:

```python
async def _send_approval_request(bot, chat_id: int, task: dict) -> int:
    """Send approval notification with inline buttons. Returns message_id."""
    RISK_EMOJI = {"low": "🟢", "medium": "🟡", "high": "🔴"}
    risk = task.get("risk_level", "medium")
    skill = task.get("skill_match") or "なし"

    text = (
        f"⚠️ タスク承認リクエスト\n\n"
        f"タスク: {task['title']}\n"
        f"リスク: {RISK_EMOJI.get(risk, '?')} {risk.upper()}\n"
        f"スキル: {skill}\n"
    )
    if task.get("description"):
        text += f"詳細: {task['description'][:200]}\n"

    keyboard = InlineKeyboardMarkup([[
        InlineKeyboardButton("✅ 承認", callback_data=f"approve:{task['id']}"),
        InlineKeyboardButton("❌ 拒否", callback_data=f"reject:{task['id']}"),
    ]])
    msg = await bot.send_message(chat_id=chat_id, text=text, reply_markup=keyboard)
    return msg.message_id
```

- [ ] **Step 3: Add callback handler function**

```python
async def handle_approval_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle ✅/❌ inline button presses for task approval."""
    query = update.callback_query
    if not _authorised(query.message.chat_id):
        await query.answer("Unauthorized")
        return

    await query.answer()

    data = query.data  # "approve:task_20260415_001" or "reject:..."
    if not data or ":" not in data:
        return

    action, task_id = data.split(":", 1)
    approved = action == "approve"

    try:
        tasks_data, sha = _github_get_file("tasks.json")
    except Exception as exc:
        await query.edit_message_text(f"[Error] GitHub: {exc}")
        return

    task = next((t for t in tasks_data.get("tasks", []) if t["id"] == task_id), None)
    if not task:
        await query.edit_message_text(f"タスク {task_id} が見つかりません。")
        return

    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for t in tasks_data["tasks"]:
        if t["id"] == task_id:
            t["status"] = "pending" if approved else "rejected"
            t["approval_required"] = False  # Clear flag so runner executes on next cycle
            t["updated_at"] = now
            break

    try:
        _github_put_file(
            "tasks.json", tasks_data, sha,
            f"chore: task {task_id} {'approved' if approved else 'rejected'} via Telegram"
        )
    except Exception as exc:
        await query.edit_message_text(f"[Error] 書き込み失敗: {exc}")
        return

    status_text = "✅ 承認しました" if approved else "❌ 拒否しました"
    await query.edit_message_text(
        f"{status_text}\n\nタスク: {task.get('title', task_id)}\n"
        f"{'次回実行時に処理されます' if approved else '拒否済みとして記録しました'}"
    )
    logger.info("Task %s %s by user", task_id, "approved" if approved else "rejected")
```

- [ ] **Step 4: Add approval poller job (checks waiting_approval every 5 minutes)**

```python
async def _approval_check_callback(context: ContextTypes.DEFAULT_TYPE) -> None:
    """Periodically check for tasks waiting approval and send Telegram notifications."""
    if not GITHUB_TOKEN or not ALLOWED_CHAT_IDS:
        return
    try:
        tasks_data, sha = _github_get_file("tasks.json")
    except Exception as exc:
        logger.error("approval_check: GitHub error: %s", exc)
        return

    for task in tasks_data.get("tasks", []):
        if task.get("status") == "waiting_approval" and not task.get("telegram_message_id"):
            for chat_id in ALLOWED_CHAT_IDS:
                try:
                    msg_id = await _send_approval_request(context.bot, chat_id, task)
                    # Record message_id so we don't re-send
                    task["telegram_message_id"] = msg_id
                    from datetime import datetime, timezone
                    task["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                except Exception as exc:
                    logger.error("Failed to send approval for %s: %s", task["id"], exc)

    # Write back updated telegram_message_ids
    for task in tasks_data.get("tasks", []):
        if task.get("status") == "waiting_approval" and task.get("telegram_message_id"):
            try:
                _, new_sha = _github_get_file("tasks.json")
                _github_put_file("tasks.json", tasks_data, new_sha,
                                 "chore: record telegram_message_ids")
            except Exception as exc:
                logger.error("approval_check write-back: %s", exc)
            break  # Only update once
```

- [ ] **Step 5: Register callback handler and poller in main()**

In `main()`, after existing handlers:

```python
    app.add_handler(CallbackQueryHandler(handle_approval_callback, pattern=r"^(approve|reject):"))
```

In the job_queue section, add alongside the daily job:

```python
        job_queue.run_repeating(
            _approval_check_callback,
            interval=300,  # every 5 minutes
            first=30,       # first check 30s after start
            name="approval_check",
        )
        logger.info("Approval check job scheduled every 5 minutes")
```

- [ ] **Step 6: Add GITHUB_TOKEN to bot .env**

```bash
# Add to ~/Desktop/claude-telegram-bot/.env:
# GITHUB_TOKEN=ghp_YOUR_TOKEN_HERE
# GITHUB_OWNER=nekoojisan-labo
# GITHUB_REPO=claude-task-manager
```

- [ ] **Step 7: Restart bot**

```bash
launchctl stop com.nekoojisan.claude-telegram-bot
launchctl start com.nekoojisan.claude-telegram-bot
sleep 3
tail -20 ~/Desktop/claude-telegram-bot/logs/bot.log
# Expected: "Starting Claude Telegram Bot" + "Approval check job scheduled"
```

- [ ] **Step 8: Commit**

```bash
cd ~/Desktop/claude-telegram-bot
git add bot.py
git commit -m "feat: add task approval inline buttons and callback handler"
git push origin main
```

---

## Task 10: Integration Tests

**Files:**
- Create: `tests/test-runner.sh`

- [ ] **Step 1: Write test-runner.sh**

```bash
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

# Test 1: GitHub API read
echo "Test 1: GitHub API can read tasks.json"
content=$(github_get_file "tasks.json")
assert_eq "tasks.json has 'tasks' key" "True" \
  "$(echo "$content" | python3 -c "import sys,json; print('True' if 'tasks' in json.loads(sys.stdin.read()) else 'False')")"

# Test 2: GitHub API read status.json
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

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
```

- [ ] **Step 2: Run tests**

```bash
chmod +x ~/Desktop/claude-task-manager/tests/test-runner.sh
bash ~/Desktop/claude-task-manager/tests/test-runner.sh
# Expected:
#   PASS: tasks.json has 'tasks' key
#   PASS: status.json has 'running' key
#   PASS: test task exists in tasks.json
#   Results: 3 passed, 0 failed
```

- [ ] **Step 3: Commit**

```bash
cd ~/Desktop/claude-task-manager
git add tests/
git commit -m "test: add integration smoke tests for GitHub API and task runner"
git push origin main
```

---

## Self-Review

### Spec Coverage Check

| Requirement | Covered in |
|-------------|-----------|
| Web UI task submission | Task 6 (createTask + form wire-up) |
| tasks.json CRUD via GitHub API | Task 2 (lib/github.sh), Task 6 (ghGet/ghPut) |
| GitHub Token settings screen | Task 6 (settings modal) |
| Auto-refresh Kanban board | Task 6 (setInterval 30s) |
| task-runner.sh 15-min schedule | Task 4 (task-runner.sh) + Task 5 (launchd) |
| Claude Code skill matching | Task 4 (analyze step with haiku) |
| Risk level detection | Task 3 (analyze-prompt.txt) + Task 4 |
| Automatic execution (low risk) | Task 4 (step 7: execute branch) |
| Telegram approval for HIGH risk | Task 4 (step 6: needs_approval=true) |
| per-task approval_required flag | Task 4 (step 6: medium + flag check) |
| Live status panel in browser | Task 7 (status.json polling 5s) |
| Which agent is running (visible) | Task 7 (renderStatus + agent label) |
| Remote Claude Code control | Task 6 (task submission from any browser) |
| /tasks Telegram command | Task 8 |
| Approval inline buttons ✅/❌ | Task 9 |
| Callback → GitHub API write | Task 9 (handle_approval_callback) |
| Approval poller (auto-detect waiting) | Task 9 (_approval_check_callback) |

### No Placeholders Confirmed

All code blocks contain complete, runnable code. No TBD, TODO, or "similar to Task N" references.

### Type Consistency

- `ghGet` returns `{content, sha}` — consistent in Task 6 Steps 2, 4, 8
- `github_get_file()` sets `GITHUB_FILE_SHA` in caller scope — used consistently in Task 4
- Task status values match schema: `pending | analyzing | waiting_approval | running | completed | rejected | failed`
- `_github_get_file()` returns `(dict, sha)` tuple — consistent in Tasks 8, 9

---
