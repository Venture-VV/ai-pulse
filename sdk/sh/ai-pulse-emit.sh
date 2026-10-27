#!/usr/bin/env bash
# ==============================================================================
# AI Pulse Shell Hook Emitter (Zero Dependencies)
# ==============================================================================
# Usage:
#   ./sdk/sh/ai-pulse-emit.sh <task_id> <app_name> <status> <title> [detail] [workspace] [model]
#
# Example (Claude Code / Codex / Git / Makefile hook):
#   ./sdk/sh/ai-pulse-emit.sh "my-build-1" "DeepSeek CLI" "running" "正在构建生产镜像" "Step 2/4 · docker build" "yuzu" "DeepSeek-R1"
# ==============================================================================

set -e

TASK_ID="${1:-custom-task}"
APP_NAME="${2:-Custom AI}"
STATUS="${3:-running}"
TITLE="${4:-自定义 AI 任务}"
DETAIL="${5:-正在执行中...}"
WORKSPACE="${6:-$(basename "$PWD")}"
MODEL="${7:-Custom-Agent}"

STATUS_DIR="${HOME}/.ai-pulse/status"
mkdir -p "${STATUS_DIR}"

NOW_SEC=$(date +%s)
TARGET_FILE="${STATUS_DIR}/${TASK_ID}.json"
TMP_FILE="${TARGET_FILE}.tmp"

cat > "${TMP_FILE}" <<EOF
{
  "id": "${TASK_ID}",
  "appName": "${APP_NAME}",
  "bundleId": "com.apple.Terminal",
  "appPath": "/System/Applications/Utilities/Terminal.app",
  "taskTitle": "${TITLE}",
  "workspace": "${WORKSPACE}",
  "fullWorkspacePath": "${PWD}",
  "statusDetail": "${DETAIL}",
  "modelName": "${MODEL}",
  "status": "${STATUS}",
  "updatedAt": ${NOW_SEC},
  "isAppRunning": true
}
EOF

mv "${TMP_FILE}" "${TARGET_FILE}"
echo "✅ Emitted [${APP_NAME}] (${STATUS}) -> ${TARGET_FILE}"
