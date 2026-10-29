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
SAFE_FILE_ID="${TASK_ID//\//_}"
SAFE_FILE_ID="${SAFE_FILE_ID//../_}"
if [ -z "${SAFE_FILE_ID}" ] || [ "${SAFE_FILE_ID}" = "." ]; then
  SAFE_FILE_ID="custom-task"
fi
TARGET_FILE="${STATUS_DIR}/${SAFE_FILE_ID}.json"
TMP_FILE="${TARGET_FILE}.tmp"

# 转义为 JSON 字符串内容：标题里的 " 或 \ 会让文件无法解析，AI Pulse 会直接跳过该任务
# 逐字符处理以兼容 macOS 自带的 bash 3.2（${var//…} 替换中的反斜杠语义在各版本间不一致）
json_escape() {
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      \\) out+="\\\\" ;;
      \") out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      [[:cntrl:]]) ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

cat > "${TMP_FILE}" <<EOF
{
  "id": "$(json_escape "${TASK_ID}")",
  "appName": "$(json_escape "${APP_NAME}")",
  "bundleId": "",
  "appPath": "",
  "taskTitle": "$(json_escape "${TITLE}")",
  "workspace": "$(json_escape "${WORKSPACE}")",
  "fullWorkspacePath": "$(json_escape "${PWD}")",
  "statusDetail": "$(json_escape "${DETAIL}")",
  "modelName": "$(json_escape "${MODEL}")",
  "status": "$(json_escape "${STATUS}")",
  "updatedAt": ${NOW_SEC},
  "isAppRunning": true
}
EOF

mv "${TMP_FILE}" "${TARGET_FILE}"
echo "✅ Emitted [${APP_NAME}] (${STATUS}) -> ${TARGET_FILE}"
