# Contributing to AI Pulse (开发者与插件扩展指南)

感谢您对 **AI Pulse** 的关注与贡献！本项目专为多 AI 工具并行工作流打造，采用三层开放扩展架构，让任何人都能在 **5 分钟内** 接入新的 AI IDE、桌面客户端、本地 Bot 或自定义 Agent 脚本。

---

## 🧩 方式一：零代码 Drop-in 实时状态上报（推荐脚本 / Bot / Hook 使用）

无需修改或重新编译 Swift 源码！任何外部程序（Python、Node.js、Shell、Claude Code Hooks、LangGraph、AutoGen 等）只需向 `~/.ai-pulse/status/<task_id>.json` 写入 JSON 文件，AI Pulse 会每 2 秒自动扫描并实时渲染到悬浮窗中。

### 1. 使用内置 Python SDK ([`sdk/python/ai_pulse.py`](./sdk/python/ai_pulse.py))

```python
from sdk.python.ai_pulse import AIPulseTask

with AIPulseTask(
    task_id="my-research-bot",
    app_name="DeepSeek Agent",
    task_title="批量抓取与交叉验证行业数据",
    workspace="market-research",
    model_name="DeepSeek-R1"
) as task:
    task.update("Step 1/3 · 正在抓取数据...", status="running")
    # 执行任务...
    task.update("Step 2/3 · 正在生成分析报告...", status="running")
# 退出 with 块时自动标记为 completed，并触发 AI Pulse 完成横幅与提示音！
```

### 2. 使用内置 Shell 工具 ([`sdk/sh/ai-pulse-emit.sh`](./sdk/sh/ai-pulse-emit.sh))

```bash
./sdk/sh/ai-pulse-emit.sh "job-01" "Grok Bot" "running" "正在执行自动化测试" "Step 2/5 · pytest" "my-repo" "grok-3"
```

### 3. 直接写入 JSON 格式规范

文件路径：`~/.ai-pulse/status/<task-id>.json`

```json
{
  "id": "custom-agent-01",
  "appName": "My Custom Bot",
  "bundleId": "com.apple.Terminal",
  "appPath": "/System/Applications/Utilities/Terminal.app",
  "taskTitle": "正在执行全量代码重构",
  "workspace": "my-project",
  "fullWorkspacePath": "/Users/me/code/my-project",
  "statusDetail": "Step 4/10 · 正在运行单元测试...",
  "modelName": "DeepSeek-R1",
  "status": "running",
  "updatedAt": 1793108000
}
```
- `status` 可选值：
  - `"running"`：狂飙中（卡片显示实时读秒计时器与流光边框）
  - `"waiting"`：等你拍板（置顶冒泡并触发橙色提醒）
  - `"completed"`：已搞定（当从 `running` 转为 `completed` 且持续超过 6 秒时触发完成通知）
  - `"error"`：有状况
  - `"idle"`：待命中

---

## ⚙️ 方式二：声明式 JSON 插件配置 (`~/.ai-pulse/plugins/*.json`)

如果您想监控某个自带本地 JSON 状态文件的桌面 AI 软件，只需在 `~/.ai-pulse/plugins/` 下新建一个 `.json` 配置文件（可参考 `~/.ai-pulse/plugins/custom-agent.json.sample`）：

```json
{
  "id": "my-ai-ide",
  "appName": "NewAI Studio",
  "bundleId": "com.newai.studio",
  "appPath": "/Applications/NewAI Studio.app",
  "modelName": "NewAI-Pro",
  "mode": "json_file",
  "filePath": "~/.newai/session_state.json",
  "titleKey": "promptTitle",
  "statusKey": "turnStatus",
  "detailKey": "currentTool",
  "workspaceKey": "projectDir"
}
```

---

## 🛠️ 方式三：原生 Swift `AITaskProvider` 协议扩展

如果您希望为社区贡献内置的深度适配器（例如解析 SQLite、LevelDB 或二进制日志），只需在 [`Sources/PluginSystem.swift`](./Sources/PluginSystem.swift) 中实现 `AITaskProvider` 协议：

```swift
struct MyNewToolProvider: AITaskProvider {
    let providerId = "my-new-tool"
    let displayName = "My New Tool"
    let bundleIds = ["com.example.mynewtool"]
    let appPaths = ["/Applications/MyNewTool.app"]

    func scan(context: TelemetryScanContext) -> [AITaskItem] {
        let isRunning = context.isAppRunning(bundleId: "com.example.mynewtool")
        // 读取本地 SQLite / JSONL 并返回 [AITaskItem]
        return []
    }
}
```

然后在 `ProviderRegistry.init()` 中注册一行：
```swift
register(MyNewToolProvider())
```

---

## 🧪 提交 PR 前的自检与压力测试要求

在提交 Pull Request 前，请确保通过编译及全部 4 项自动化压力测试：

```bash
# 1. 编译打包
./build.sh

# 2. 运行本机全量扫描自检
"./AI Pulse.app/Contents/MacOS/AIPulse" --self-test

# 3. 运行高并发与防通知轰炸压力测试套件
"./AI Pulse.app/Contents/MacOS/AIPulse" --stress-test
```
