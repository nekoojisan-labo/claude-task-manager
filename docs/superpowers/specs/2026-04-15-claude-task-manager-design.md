# Claude Task Manager — 設計書

**作成日:** 2026-04-15  
**ステータス:** 承認済み（モックアップ確認完了）

---

## 概要

Web UI からタスクを登録し、Claude Code がスケジュール実行でタスクを処理するシステム。
リスクの高い操作は Telegram Bot 経由でユーザーの承認を取ってから実行する。

---

## アーキテクチャ

```
iPhone / ブラウザ
  └─ GitHub Pages (index.html)
       └─ GitHub API → tasks.json (リポジトリ内)
                           └─ launchd (15分ごと)
                                └─ task-runner.sh
                                     ├─ Claude Code (解析・実行)
                                     └─ Telegram Bot (承認通知)
                                          └─ ユーザー ✅/❌
                                               └─ GitHub API (ステータス更新)
```

---

## コンポーネント

### 1. Web UI（GitHub Pages）

**リポジトリ:** https://github.com/nekoojisan-labo/claude-task-manager  
**URL:** https://nekoojisan-labo.github.io/claude-task-manager/

**機能:**
- タスク追加フォーム（タイトル・詳細・種別・実行タイミング・承認フラグ）
- Kanban ボード（未着手 / 解析中 / 承認待ち / 実行中 / 完了）
- GitHub API で `tasks.json` を読み書き
- GitHub Personal Access Token をローカルストレージに保存（初回設定）

**デザイン:**
- パープル系グラデーション + ライトモード
- 明朝体（Noto Serif JP）+ ゆったりサイズ
- Tailwind CSS CDN

---

### 2. タスクデータ（tasks.json）

```json
{
  "tasks": [
    {
      "id": "task_YYYYMMDD_NNN",
      "title": "string",
      "description": "string",
      "type": "automation | development | content | research | memo | other",
      "status": "pending | analyzing | waiting_approval | running | completed | rejected | failed",
      "approval_required": false,
      "risk_level": "low | medium | high",
      "skill_match": "string | null",
      "skill_status": "exists | suggest_create | none",
      "workflow_steps": [],
      "created_at": "ISO8601",
      "updated_at": "ISO8601",
      "executed_at": "ISO8601 | null",
      "result": "string | null",
      "telegram_message_id": "number | null"
    }
  ]
}
```

**リスク判定基準:**
- `high`: ファイル削除・外部API送信・Git プッシュ・課金発生 → 自動承認しない
- `medium`: ファイル変更・新規ファイル作成 → `approval_required: true` 時のみ承認求める
- `low`: 読み取り・生成・Obsidian 書き込みのみ → 自動実行

---

### 3. Task Runner（Mac ローカル）

**ファイル:** `~/Desktop/claude-task-manager/task-runner.sh`  
**スケジュール:** launchd で15分ごと実行（`com.nekoojisan.claude-task-manager`）

**処理フロー:**
1. GitHub API から `tasks.json` を取得
2. `status: pending` のタスクを取得
3. Claude Code でタスクを解析（スキルマッチ・リスク判定・ワークフロー生成）
4. `status: analyzing` に更新
5. リスク判定:
   - `high` → 必ず Telegram に承認通知、`status: waiting_approval`
   - `medium` + `approval_required: true` → Telegram に承認通知
   - それ以外 → 自動実行
6. Claude Code でタスク実行
7. 結果を `tasks.json` に書き込み（GitHub API）

**スキルマッチロジック:**
- Claude Code が `~/.claude/agents/` 配下のスキル一覧を参照
- タスク内容と照合して最適スキルを提案
- マッチなし → `skill_status: suggest_create` でスキル作成を提案（Telegram通知）

---

### 4. Telegram Bot 拡張（既存 bot.py）

**追加コマンド:**
- `/tasks` — pending タスク一覧を表示

**承認通知フォーマット:**
```
⚠️ タスク承認リクエスト

タスク: GitHub Pages の設定を更新してデプロイする
リスク: HIGH（外部デプロイを含む操作）
スキル: deployment-patterns

承認しますか？
[✅ 承認] [❌ 拒否]
```

**承認フロー:**
1. ユーザーがインラインボタンを押す
2. bot.py がコールバックを受信
3. GitHub API で `tasks.json` の該当タスクを更新（`approved` / `rejected`）
4. 次回 task-runner.sh 実行時にステータスを確認して処理

---

## ファイル構成

```
~/Desktop/claude-task-manager/
├── index.html              # Web UI（GitHub Pages）
├── docs/
│   └── superpowers/specs/
│       └── 2026-04-15-claude-task-manager-design.md
├── task-runner.sh          # タスク実行スクリプト（未実装）
├── tasks.json              # タスクデータ（未実装）
└── launchd/
    └── com.nekoojisan.claude-task-manager.plist  # 未実装
```

既存ファイル（拡張）:
```
~/Desktop/claude-telegram-bot/
└── bot.py                  # Telegram Bot（/tasks コマンド・承認フロー追加）
```

---

## 実装フェーズ

### Phase 1: Web UI 完成
- GitHub API 連携（tasks.json の CRUD）
- 設定画面（GitHub Token 入力）
- リアルタイムステータス更新（ポーリング）

### Phase 2: Task Runner
- `task-runner.sh` 実装
- Claude Code によるスキルマッチ・リスク判定
- launchd 登録

### Phase 3: Telegram Bot 拡張
- bot.py に `/tasks` コマンド追加
- 承認通知（インラインボタン）
- コールバック処理 → GitHub API 書き込み

---

## 非機能要件

- **セキュリティ:** GitHub Token はローカルストレージのみ（サーバー送信なし）
- **可用性:** Mac がスリープ中は実行されない（launchd の仕様上許容）
- **データ:** tasks.json はGitHub上で管理 → バージョン履歴付き
