import Cocoa
import Foundation
import SQLite3

// MARK: - 1. Open-Source Extensible Provider Protocol (开放式插件扩展协议)

/// 传递给每个 Provider 的只读扫描上下文（避免各插件重复查询进程列表与 CPU）
struct TelemetryScanContext {
    let homeDir: String
    let runningBundleIds: Set<String>
    let cpuByKeyword: [String: Double]
    let statusDirOverride: String?
    let pluginsDirOverride: String?

    func isAppRunning(bundleId: String, fallbackCPU: Double = 0) -> Bool {
        runningBundleIds.contains(bundleId) || fallbackCPU > 0.1
    }

    func cpu(for key: String) -> Double {
        cpuByKeyword[key] ?? 0.0
    }
}

/// 任何第三方开发者只需实现 `AITaskProvider` 协议并注册到 `ProviderRegistry`，
/// 即可为 AI Pulse 接入新的 AI IDE、桌面 Agent 或终端工具。
protocol AITaskProvider {
    /// 插件唯一标识，例如 `"deepseek"`、`"grok-bot"`
    var providerId: String { get }
    /// 显示名称，例如 `"DeepSeek"`、`"Grok Bot"`
    var displayName: String { get }
    /// 关联的 macOS Bundle IDs（用于窗口跳转与图标提取）
    var bundleIds: [String] { get }
    /// 关联的应用路径（用于未启动时提取图标或唤醒）
    var appPaths: [String] { get }
    /// 执行单次非阻塞状态扫描
    func scan(context: TelemetryScanContext) -> [AITaskItem]
}

// MARK: - 2. Provider Registry & Plugin Directory Bootstrap

final class ProviderRegistry {
    static let shared = ProviderRegistry()

    private var providers: [AITaskProvider] = []

    private init() {
        bootstrapPluginDirectoriesIfNeeded()
        // 默认注册内置的模块化 Provider
        register(DeepSeekProvider())
        register(GrokBotProvider())
        register(DropInStatusProvider())
        register(DeclarativePluginProvider())
    }

    func register(_ provider: AITaskProvider) {
        if !providers.contains(where: { $0.providerId == provider.providerId }) {
            providers.append(provider)
        }
    }

    var registeredProviders: [AITaskProvider] {
        providers
    }

    func scanAll(context: TelemetryScanContext) -> [AITaskItem] {
        var results: [AITaskItem] = []
        for provider in providers {
            results.append(contentsOf: provider.scan(context: context))
        }
        return results
    }

    public var baseDirectoryPath: String {
        "\(NSHomeDirectory())/.ai-pulse"
    }

    public var statusDirectoryPath: String {
        "\(baseDirectoryPath)/status"
    }

    public var pluginsDirectoryPath: String {
        "\(baseDirectoryPath)/plugins"
    }

    /// 首次启动时自动创建 `~/.ai-pulse/{status,plugins}` 及示例文件，方便开源用户零门槛接入
    public func bootstrapPluginDirectoriesIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: statusDirectoryPath, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: pluginsDirectoryPath, withIntermediateDirectories: true)

        let readmePath = "\(baseDirectoryPath)/README.md"
        if !fm.fileExists(atPath: readmePath) {
            let doc = """
            # AI Pulse 开放插件与实时状态接入中心 (~/.ai-pulse)

            欢迎使用 AI Pulse 扩展接口！您无需修改或重新编译 Swift 源码，即可通过以下两种方式接入任何自定义 AI 工具、Agent 脚本或本地 Bot：

            ## 方式一：零代码 Drop-in 实时状态文件 (`~/.ai-pulse/status/*.json`)
            任何 Python / Node.js / Shell 脚本或 Agent Hook 只需向 `~/.ai-pulse/status/<task-id>.json` 写入如下 JSON：
            ```json
            {
              "id": "my-custom-agent-1",
              "appName": "DeepSeek Agent",
              "bundleId": "com.deepseek.dsh",
              "appPath": "/Applications/DeepSeek Harness.app",
              "taskTitle": "正在执行全量代码审查与单测生成",
              "workspace": "my-project",
              "fullWorkspacePath": "/Users/me/projects/my-project",
              "statusDetail": "Step 4/10 · 正在运行 pytest...",
              "modelName": "DeepSeek-R1",
              "status": "running",
              "updatedAt": 1793108000
            }
            ```
            - `status` 支持：`"running"`（狂飙中）、`"waiting"`（等你拍板）、`"completed"`（已搞定）、`"error"`（有状况）、`"idle"`（待命中）。
            - 当 `status` 从 `"running"` 变为 `"completed"` 或 `"waiting"` 时，AI Pulse 会自动弹出完成横幅、播放提示音并支持一键窗口闪现！

            ## 方式二：声明式 JSON 插件配置 (`~/.ai-pulse/plugins/*.json`)
            将 `.sample` 后缀去掉即可启用自定义应用或状态文件监控。
            """
            try? doc.write(toFile: readmePath, atomically: true, encoding: .utf8)
        }

        let sampleStatusPath = "\(statusDirectoryPath)/example-bot.json.sample"
        if !fm.fileExists(atPath: sampleStatusPath) {
            let sample = """
            {
              "id": "sample-custom-bot",
              "appName": "Custom AI Bot",
              "bundleId": "com.apple.Terminal",
              "appPath": "/System/Applications/Utilities/Terminal.app",
              "taskTitle": "示例：在 ~/.ai-pulse/status/ 下写入 .json 即可实时上屏",
              "workspace": "ai-pulse",
              "statusDetail": "Step 1 · 准备就绪",
              "modelName": "Custom-LLM",
              "status": "completed"
            }
            """
            try? sample.write(toFile: sampleStatusPath, atomically: true, encoding: .utf8)
        }

        let samplePluginPath = "\(pluginsDirectoryPath)/custom-agent.json.sample"
        if !fm.fileExists(atPath: samplePluginPath) {
            let samplePlugin = """
            {
              "id": "my-custom-ide",
              "appName": "My AI Agent",
              "bundleId": "com.example.myagent",
              "appPath": "/Applications/MyAgent.app",
              "category": "AI 桌面",
              "modelName": "Custom-Model",
              "mode": "json_file",
              "filePath": "~/.myagent/state.json",
              "titleKey": "currentTask",
              "statusKey": "state",
              "detailKey": "stepText",
              "workspaceKey": "cwd"
            }
            """
            try? samplePlugin.write(toFile: samplePluginPath, atomically: true, encoding: .utf8)
        }
    }

    public func openPluginFolderInFinder() {
        bootstrapPluginDirectoriesIfNeeded()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: baseDirectoryPath)
    }
}

// MARK: - 3. DeepSeek Provider (DeepSeek Harness.app + ~/.dsh)

struct DeepSeekProvider: AITaskProvider {
    let providerId = "deepseek"
    let displayName = "DeepSeek"
    let bundleIds = ["com.deepseek.dsh", "com.deepseek.chat"]
    let appPaths = ["/Applications/DeepSeek Harness.app", "/Applications/DeepSeek.app"]

    init() {}

    func scan(context: TelemetryScanContext) -> [AITaskItem] {
        let bundleId = "com.deepseek.dsh"
        let appPath = "/Applications/DeepSeek Harness.app"
        let cpu = context.cpu(for: "deepseek")
        let isRunning = context.isAppRunning(bundleId: bundleId, fallbackCPU: cpu)
        let projCacheDir = "\(context.homeDir)/.dsh/storages/session_projcache/sessions"

        var items: [AITaskItem] = []
        let fm = FileManager.default

        if let files = try? fm.contentsOfDirectory(atPath: projCacheDir) {
            var sessionFiles: [(id: String, path: String, modDate: Date)] = []
            for file in files where file.hasSuffix(".json") {
                let fullPath = "\(projCacheDir)/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    let sid = String(file.dropLast(5))
                    sessionFiles.append((id: sid, path: fullPath, modDate: modDate))
                }
            }
            sessionFiles.sort { $0.modDate > $1.modDate }

            // 遍历最近的会话，过滤空白会话与纯子 Agent 内部缓存，取最新 2 个主会话
            for info in sessionFiles.prefix(12) {
                if items.count >= 2 { break }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: info.path)),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let record = root["record"] as? [String: Any],
                      let rows = record["rows"] as? [String: Any] else { continue }

                // 检查是否为空白未使用的会话
                if let listMeta = (rows["sessionListMetadata"] as? [String: Any])?["val"] as? [String: Any],
                   let isBlank = listMeta["blank"] as? Bool, isBlank == true {
                    continue
                }

                // 提取工作目录
                let identity = record["identity"] as? [String: Any] ?? [:]
                let workDirRow = (rows["workingDirectory"] as? [String: Any])?["val"] as? String
                let cwd = workDirRow ?? (identity["cwd"] as? String ?? "")
                let wsName = cwd.isEmpty ? "deepseek" : (cwd as NSString).lastPathComponent

                // 提取标题与最近一轮 Prompt
                var titleText = ((rows["title"] as? [String: Any])?["val"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                var lastResponseSnippet = ""
                if let outlineVal = (rows["turnOutline"] as? [String: Any])?["val"] as? [String: Any],
                   let turns = outlineVal["turns"] as? [[String: Any]],
                   let lastTurn = turns.last {
                    let prompt = (lastTurn["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let resp = (lastTurn["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if titleText.isEmpty && !prompt.isEmpty {
                        titleText = prompt
                    }
                    if !resp.isEmpty {
                        lastResponseSnippet = resp.replacingOccurrences(of: "\n", with: " ")
                    }
                }

                if titleText.isEmpty,
                   let titleInputVal = (rows["titleInput"] as? [String: Any])?["val"] as? [String: Any],
                   let firstObj = titleInputVal["first"] as? [String: Any],
                   let firstText = firstObj["text"] as? String {
                    let firstLine = firstText.split(separator: "\n").first.map(String.init) ?? firstText
                    titleText = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if titleText.isEmpty { continue }
                let cleanTitle = String(titleText.replacingOccurrences(of: "\n", with: " ").prefix(62))

                // 提取模型名
                var modelName = "DeepSeek"
                if let modelSel = (rows["modelSelection"] as? [String: Any])?["val"] as? [String: Any],
                   let lastUsed = modelSel["lastUsed"] as? [String: Any],
                   let rawModel = lastUsed["model"] as? String, !rawModel.isEmpty {
                    modelName = rawModel
                }

                // 提取步数与状态
                var stepsCount = 0
                if let statsVal = (rows["sessionStats"] as? [String: Any])?["val"] as? [String: Any],
                   let steps = statsVal["steps"] as? Int {
                    stepsCount = steps
                }

                var hasActiveQuestion = false
                if let uqVal = (rows["userQuestions"] as? [String: Any])?["val"] as? [String: Any],
                   let qObj = uqVal["questions"] as? [String: Any],
                   let activeArr = qObj["active"] as? [Any], !activeArr.isEmpty {
                    hasActiveQuestion = true
                }

                var isTurnOpen = false
                var boundarySeq = 0
                if let tbRow = rows["turnBoundary"] as? [String: Any] {
                    boundarySeq = tbRow["seq"] as? Int ?? 0
                    if let tbVal = tbRow["val"] as? [String: Any] {
                        if let openSeq = tbVal["openTurnStartSeq"], !(openSeq is NSNull) {
                            isTurnOpen = true
                        }
                        if let lastStepBoundary = tbVal["lastStepBoundary"] as? [String: Any],
                           let kind = lastStepBoundary["kind"] as? String, kind == "start" {
                            isTurnOpen = true
                        }
                    }
                }

                // 检查是否有活跃的子 Agent 团队成员
                var teamCount = 0
                if let teamVal = (rows["agentTeam"] as? [String: Any])?["val"] as? [String: Any],
                   let members = teamVal["members"] as? [Any] {
                    teamCount = members.count
                }

                let ageSec = Date().timeIntervalSince(info.modDate)
                let status: TaskStatus
                let detail: String
                let sig: String

                if hasActiveQuestion && ageSec < 1800 {
                    status = .waiting
                    detail = "DeepSeek 等待您回答问题或确认方案"
                    sig = "deepseek-wait-\(info.id)-\(boundarySeq)"
                } else if isTurnOpen && ageSec < 300 && isRunning {
                    status = .running
                    let stepPart = stepsCount > 0 ? "Step \(stepsCount) · " : ""
                    let teamPart = teamCount > 0 ? "(\(teamCount) 子Agent协同) " : ""
                    detail = "\(stepPart)\(teamPart)DeepSeek 正在深度推理与执行..."
                    sig = ""
                } else {
                    status = .completed
                    if stepsCount > 0 {
                        let teamSuffix = teamCount > 0 ? " · \(teamCount) 子Agent协同" : ""
                        detail = "已完成推理任务 (共 \(stepsCount) 步\(teamSuffix))"
                    } else if !lastResponseSnippet.isEmpty {
                        detail = String(lastResponseSnippet.prefix(42))
                    } else {
                        detail = "DeepSeek 任务已完成"
                    }
                    sig = "deepseek-done-\(info.id)-\(boundarySeq)"
                }

                items.append(AITaskItem(
                    id: "deepseek-\(info.id)",
                    appName: "DeepSeek",
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .desktop,
                    taskTitle: cleanTitle,
                    workspace: wsName,
                    fullWorkspacePath: cwd,
                    statusDetail: detail,
                    modelName: modelName,
                    status: status,
                    cpuPercent: cpu,
                    updatedAt: info.modDate,
                    isAppRunning: isRunning,
                    completionSignature: sig,
                    canTriggerAlert: true
                ))
            }
        }

        if items.isEmpty && isRunning {
            items.append(AITaskItem(
                id: "deepseek-app",
                appName: "DeepSeek",
                bundleId: bundleId,
                appPath: appPath,
                category: .desktop,
                taskTitle: "DeepSeek Harness 在线",
                workspace: "默认工作区",
                fullWorkspacePath: "\(context.homeDir)/deepseek",
                statusDetail: "等待新任务触发",
                modelName: "DeepSeek",
                status: .idle,
                cpuPercent: cpu,
                updatedAt: Date(),
                isAppRunning: true,
                completionSignature: "deepseek-idle",
                canTriggerAlert: false
            ))
        }

        return items
    }
}

// MARK: - 4. Grok Bot Provider (Grok Bot.app + ~/.grokbot + ~/.grok)

struct GrokBotProvider: AITaskProvider {
    let providerId = "grok-bot"
    let displayName = "Grok Bot"
    let bundleIds = ["com.anysphere.sand", "ai.x.grok"]
    let appPaths = [
        "/Applications/Grok Bot.app",
        "\(NSHomeDirectory())/.grokbot/computer-use/Grok Bot Computer Use.app"
    ]

    init() {}

    func scan(context: TelemetryScanContext) -> [AITaskItem] {
        let bundleId = "com.anysphere.sand"
        let appPath = "/Applications/Grok Bot.app"
        let cpu = context.cpu(for: "grok")
        var isRunning = context.isAppRunning(bundleId: bundleId, fallbackCPU: cpu)

        let daemonJsonPath = "\(context.homeDir)/.grokbot/local-exec-daemon.json"
        let persistenceDir = "\(context.homeDir)/Library/Application Support/Grok Bot/sand-client-persistence"
        let grokCliDbPath = "\(context.homeDir)/.grok/sessions/session_search.sqlite"

        var items: [AITaskItem] = []
        let fm = FileManager.default

        // 1. 检查 ~/.grokbot/local-exec-daemon.json 中的本地执行守护进程状态与 inflightCount
        var inflightCount = 0
        if let dData = try? Data(contentsOf: URL(fileURLWithPath: daemonJsonPath)),
           let dJson = try? JSONSerialization.jsonObject(with: dData) as? [String: Any] {
            inflightCount = dJson["inflightCount"] as? Int ?? 0
            if let servingAtMs = dJson["servingAt"] as? Double {
                let servingDate = Date(timeIntervalSince1970: servingAtMs / 1000.0)
                if Date().timeIntervalSince(servingDate) < 3600 {
                    isRunning = true
                }
            }
        }

        // 2. 解析 ~/Library/Application Support/Grok Bot/sand-client-persistence/*.blob
        if let blobFiles = try? fm.contentsOfDirectory(atPath: persistenceDir) {
            var rosterRows: [[String: Any]] = []
            var streamingByBotText: [String: Bool] = [:]

            for file in blobFiles where file.hasSuffix(".blob") {
                let fullPath = "\(persistenceDir)/\(file)"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let val = json["value"] as? [String: Any] else { continue }

                if let rows = val["rows"] as? [[String: Any]] {
                    rosterRows = rows
                } else if let entries = val["entries"] as? [[String: Any]], let lastEntry = entries.last {
                    if let isStreaming = lastEntry["isStreaming"] as? Bool, isStreaming == true {
                        let reqId = lastEntry["requestId"] as? String ?? file
                        streamingByBotText[reqId] = true
                    }
                }
            }

            // 按 lastActivityAt / updatedAt 排序，取最近活跃的 2 个 Grok Bot 助手（如 Jago、Vin、夜店舞美预制菜工作流）
            let sortedBots = rosterRows.filter { row in
                let hidden = row["isHiddenFromSidebar"] as? Bool ?? false
                let removed = row["isRemovedFromSidebar"] as? Bool ?? false
                return !hidden && !removed
            }.sorted { a, b in
                let tA = (a["lastActivityAt"] as? Double) ?? (a["updatedAt"] as? Double ?? 0)
                let tB = (b["lastActivityAt"] as? Double) ?? (b["updatedAt"] as? Double ?? 0)
                return tA > tB
            }

            for (idx, bot) in sortedBots.prefix(2).enumerated() {
                let botId = bot["id"] as? String ?? "bot-\(idx)"
                let botName = (bot["name"] as? String ?? "Grok Bot").trimmingCharacters(in: .whitespacesAndNewlines)
                let lastActMs = (bot["lastActivityAt"] as? Double) ?? (bot["updatedAt"] as? Double ?? 0)
                let updatedDate = lastActMs > 0 ? Date(timeIntervalSince1970: lastActMs / 1000.0) : Date()
                let ageSec = Date().timeIntervalSince(updatedDate)

                var lastPreview = ""
                if let lastEntry = bot["lastEntry"] as? [String: Any] {
                    if let text = lastEntry["text"] as? String, !text.isEmpty {
                        lastPreview = text
                    } else if let sp = lastEntry["sessionPreview"] as? [String: Any],
                              let spText = sp["text"] as? String, !spText.isEmpty {
                        lastPreview = spText
                    }
                }
                let cleanPreview = String(lastPreview.replacingOccurrences(of: "\n", with: " ").prefix(62))
                let taskTitle = cleanPreview.isEmpty ? "Bot 助理：\(botName)" : cleanPreview

                let awaitingUser = (bot["awaitingUserResponse"] as? Bool) ?? false
                let hasUnread = (bot["hasUnread"] as? Bool) ?? false
                let newestId = bot["newestEntryId"] as? String ?? "\(Int(lastActMs))"

                let status: TaskStatus
                let detail: String
                let sig: String

                if idx == 0 && (inflightCount > 0 || !streamingByBotText.isEmpty) && ageSec < 300 && isRunning {
                    status = .running
                    detail = inflightCount > 0
                        ? "[\(botName)] 正在执行本机 Computer-Use 指令 (\(inflightCount) 项)..."
                        : "[\(botName)] Grok Bot 正在流式生成回复..."
                    sig = ""
                } else if awaitingUser && ageSec < 3600 {
                    status = .waiting
                    detail = "[\(botName)] 等待您的确认或回复"
                    sig = "grok-wait-\(botId)-\(newestId)"
                } else {
                    status = .completed
                    detail = hasUnread ? "[\(botName)] 有新进展汇报（未读）" : "[\(botName)] 任务已就绪 · 随时待命"
                    sig = "grok-done-\(botId)-\(newestId)"
                }

                items.append(AITaskItem(
                    id: "grok-bot-\(botId)",
                    appName: "Grok Bot",
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .desktop,
                    taskTitle: taskTitle,
                    workspace: botName,
                    fullWorkspacePath: "\(context.homeDir)/.grokbot",
                    statusDetail: detail,
                    modelName: "Grok · \(botName)",
                    status: status,
                    cpuPercent: cpu,
                    updatedAt: updatedDate,
                    isAppRunning: isRunning,
                    completionSignature: sig,
                    canTriggerAlert: true
                ))
            }
        }

        // 3. 兼容 Grok CLI (~/.grok/sessions/session_search.sqlite)
        if items.isEmpty, fm.fileExists(atPath: grokCliDbPath) {
            var db: OpaquePointer?
            if sqlite3_open_v2(grokCliDbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }
                sqlite3_busy_timeout(db, 300)
                let sql = "SELECT session_id, cwd, updated_at, title FROM session_docs ORDER BY updated_at DESC LIMIT 1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(stmt) }
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        let sid = stmt.flatMap { sqlite3_column_text($0, 0) }.map { String(cString: $0) } ?? "grok-cli"
                        let cwd = stmt.flatMap { sqlite3_column_text($0, 1) }.map { String(cString: $0) } ?? ""
                        let updatedSec = sqlite3_column_int64(stmt, 2)
                        let title = stmt.flatMap { sqlite3_column_text($0, 3) }.map { String(cString: $0) } ?? "Grok CLI 会话"
                        let updatedDate = Date(timeIntervalSince1970: TimeInterval(updatedSec > 10_000_000_000 ? updatedSec / 1000 : updatedSec))
                        let wsName = cwd.isEmpty ? "grok" : (cwd as NSString).lastPathComponent

                        items.append(AITaskItem(
                            id: "grok-cli-\(sid)",
                            appName: "Grok Bot",
                            bundleId: bundleId,
                            appPath: appPath,
                            category: .cli,
                            taskTitle: String(title.replacingOccurrences(of: "\n", with: " ").prefix(62)),
                            workspace: wsName,
                            fullWorkspacePath: cwd,
                            statusDetail: "Grok CLI 会话已就绪",
                            modelName: "Grok CLI",
                            status: .completed,
                            cpuPercent: cpu,
                            updatedAt: updatedDate,
                            isAppRunning: isRunning,
                            completionSignature: "grok-cli-done-\(sid)-\(updatedSec)",
                            canTriggerAlert: true
                        ))
                    }
                }
            }
        }

        return items
    }
}

// MARK: - 5. Zero-Code Drop-In Status Provider (~/.ai-pulse/status/*.json)

struct DropInStatusProvider: AITaskProvider {
    let providerId = "dropin-status"
    let displayName = "Drop-in Status API"
    let bundleIds: [String] = []
    let appPaths: [String] = []

    init() {}

    func scan(context: TelemetryScanContext) -> [AITaskItem] {
        let dir = context.statusDirOverride ?? ProviderRegistry.shared.statusDirectoryPath
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var items: [AITaskItem] = []
        for file in files.sorted() where file.hasSuffix(".json") {
            let fullPath = "\(dir)/\(file)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let id = json["id"] as? String ?? "custom-\(file.dropLast(5))"
            let appName = json["appName"] as? String ?? "Custom Bot"
            let bundleId = json["bundleId"] as? String ?? "com.apple.Terminal"
            let appPath = json["appPath"] as? String ?? "/System/Applications/Utilities/Terminal.app"
            let taskTitle = json["taskTitle"] as? String ?? "自定义任务"
            let workspace = json["workspace"] as? String ?? "custom"
            let fullWorkspacePath = json["fullWorkspacePath"] as? String ?? ""
            let statusDetail = json["statusDetail"] as? String ?? "来自 ~/.ai-pulse/status 实时上报"
            let modelName = json["modelName"] as? String ?? "Custom Agent"
            let rawStatus = (json["status"] as? String ?? "completed").lowercased()

            let status: TaskStatus
            switch rawStatus {
            case "running", "in_progress", "working", "busy": status = .running
            case "waiting", "pending", "approval": status = .waiting
            case "error", "failed": status = .error
            case "idle": status = .idle
            default: status = .completed
            }

            let modDate: Date
            if let ts = json["updatedAt"] as? Double {
                modDate = Date(timeIntervalSince1970: ts > 10_000_000_000 ? ts / 1000.0 : ts)
            } else if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let fMod = attrs[.modificationDate] as? Date {
                modDate = fMod
            } else {
                modDate = Date()
            }

            let sig = status == .running ? "" : (json["completionSignature"] as? String ?? "dropin-\(id)-\(status.rawValue)-\(Int(modDate.timeIntervalSince1970))")
            let isOnline = (json["isAppRunning"] as? Bool) ?? (status == .running || status == .waiting || context.runningBundleIds.contains(bundleId))

            items.append(AITaskItem(
                id: id,
                appName: appName,
                bundleId: bundleId,
                appPath: appPath,
                category: .plugin,
                taskTitle: String(taskTitle.prefix(64)),
                workspace: workspace,
                fullWorkspacePath: fullWorkspacePath,
                statusDetail: statusDetail,
                modelName: modelName,
                status: status,
                cpuPercent: json["cpuPercent"] as? Double ?? 0.0,
                updatedAt: modDate,
                isAppRunning: isOnline,
                completionSignature: sig,
                canTriggerAlert: true
            ))
        }
        return items
    }
}

// MARK: - 6. Declarative JSON Plugin Provider (~/.ai-pulse/plugins/*.json)

struct DeclarativePluginProvider: AITaskProvider {
    let providerId = "declarative-plugins"
    let displayName = "Declarative Plugins"
    let bundleIds: [String] = []
    let appPaths: [String] = []

    init() {}

    func scan(context: TelemetryScanContext) -> [AITaskItem] {
        let dir = context.pluginsDirOverride ?? ProviderRegistry.shared.pluginsDirectoryPath
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var items: [AITaskItem] = []
        for file in files.sorted() where file.hasSuffix(".json") {
            let fullPath = "\(dir)/\(file)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                  let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let id = cfg["id"] as? String ?? "plugin-\(file.dropLast(5))"
            let appName = cfg["appName"] as? String ?? id
            let bundleId = cfg["bundleId"] as? String ?? ""
            let appPath = (cfg["appPath"] as? String ?? "").replacingOccurrences(of: "~", with: context.homeDir)
            let modelName = cfg["modelName"] as? String ?? appName
            let mode = (cfg["mode"] as? String ?? "json_file").lowercased()
            let isAppOnline = !bundleId.isEmpty && context.runningBundleIds.contains(bundleId)

            if mode == "json_file", let rawTarget = cfg["filePath"] as? String {
                let targetPath = rawTarget.replacingOccurrences(of: "~", with: context.homeDir)
                guard let tData = try? Data(contentsOf: URL(fileURLWithPath: targetPath)),
                      let tJson = try? JSONSerialization.jsonObject(with: tData) as? [String: Any] else { continue }

                let titleKey = cfg["titleKey"] as? String ?? "title"
                let statusKey = cfg["statusKey"] as? String ?? "status"
                let detailKey = cfg["detailKey"] as? String ?? "detail"
                let workspaceKey = cfg["workspaceKey"] as? String ?? "workspace"

                let title = (tJson[titleKey] as? String) ?? "\(appName) 任务"
                let rawStatus = ((tJson[statusKey] as? String) ?? "completed").lowercased()
                let detail = (tJson[detailKey] as? String) ?? "\(appName) 状态已同步"
                let ws = (tJson[workspaceKey] as? String) ?? appName

                let status: TaskStatus
                switch rawStatus {
                case "running", "in_progress", "working", "busy": status = .running
                case "waiting", "pending", "approval": status = .waiting
                case "error", "failed": status = .error
                case "idle": status = .idle
                default: status = .completed
                }

                let modDate = (try? fm.attributesOfItem(atPath: targetPath)[.modificationDate] as? Date) ?? Date()
                let sig = status == .running ? "" : "plugin-\(id)-\(rawStatus)-\(Int(modDate.timeIntervalSince1970))"

                items.append(AITaskItem(
                    id: "plugin-\(id)",
                    appName: appName,
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .plugin,
                    taskTitle: String(title.prefix(64)),
                    workspace: (ws as NSString).lastPathComponent,
                    fullWorkspacePath: ws,
                    statusDetail: detail,
                    modelName: modelName,
                    status: status,
                    cpuPercent: 0,
                    updatedAt: modDate,
                    isAppRunning: isAppOnline || status == .running,
                    completionSignature: sig,
                    canTriggerAlert: true
                ))
            } else if mode == "process" && isAppOnline {
                items.append(AITaskItem(
                    id: "plugin-proc-\(id)",
                    appName: appName,
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .plugin,
                    taskTitle: "\(appName) 正在后台运行",
                    workspace: appName,
                    fullWorkspacePath: "",
                    statusDetail: "通过声明式插件监控中",
                    modelName: modelName,
                    status: .idle,
                    cpuPercent: 0,
                    updatedAt: Date(),
                    isAppRunning: true,
                    completionSignature: "plugin-proc-\(id)-idle",
                    canTriggerAlert: false
                ))
            }
        }
        return items
    }
}

// MARK: - 7. Automated Stress Test & Verification Suite (--stress-test)

public enum StressTestRunner {
    public static func runAll() -> Bool {
        print("====================================================================")
        print("🚀 AI Pulse Automated Stress Test & Resilience Benchmark Suite")
        print("====================================================================")

        var allPassed = true

        // Suite 1: Live Multi-Provider Concurrency & Scan Latency Benchmark
        print("\n[Suite 1/4] Live Multi-Provider Concurrency & Scan Latency (30 iterations)...")
        let engine = TelemetryEngine(autoStart: false)
        var latenciesMs: [Double] = []
        var detectedCount = 0
        for _ in 0..<30 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let results = engine.performSynchronousSelfTest()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            latenciesMs.append(elapsedMs)
            detectedCount = results.count
        }
        let avgMs = latenciesMs.reduce(0, +) / Double(max(1, latenciesMs.count))
        let maxMs = latenciesMs.max() ?? 0
        let minMs = latenciesMs.min() ?? 0
        print(String(format: "  ✓ Detected %d live AI tasks | Latency min=%.2fms, avg=%.2fms, max=%.2fms", detectedCount, minMs, avgMs, maxMs))
        if avgMs > 500.0 {
            print("  ✗ FAIL: Scan latency too high (>500ms)")
            allPassed = false
        }

        // Suite 2: 100-Task High-Concurrency Synthetic Flood via DropInStatusProvider
        print("\n[Suite 2/4] 100-Task Synthetic Flood & State Transition Benchmark...")
        let tempDir = "\(NSTemporaryDirectory())ai-pulse-stress-\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        let tFloodStart = CFAbsoluteTimeGetCurrent()
        for i in 0..<100 {
            let statusStr: String
            switch i % 4 {
            case 0: statusStr = "running"
            case 1: statusStr = "waiting"
            case 2: statusStr = "completed"
            default: statusStr = "idle"
            }
            let payload: [String: Any] = [
                "id": "stress-task-\(i)",
                "appName": i % 2 == 0 ? "DeepSeek" : "Grok Bot",
                "bundleId": i % 2 == 0 ? "com.deepseek.dsh" : "com.anysphere.sand",
                "taskTitle": "压力测试并发任务 #\(i) - 验证高密度卡片排序与吞吐性能",
                "workspace": "stress-ws-\(i % 10)",
                "statusDetail": "Step \(i) · 并发压测执行中",
                "modelName": i % 2 == 0 ? "deepseek-reasoner" : "grok-3",
                "status": statusStr,
                "updatedAt": Date().timeIntervalSince1970
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? data.write(to: URL(fileURLWithPath: "\(tempDir)/task-\(i).json"))
            }
        }
        let ctx = TelemetryScanContext(
            homeDir: NSHomeDirectory(),
            runningBundleIds: ["com.deepseek.dsh", "com.anysphere.sand"],
            cpuByKeyword: [:],
            statusDirOverride: tempDir,
            pluginsDirOverride: tempDir
        )
        let dropInItems = DropInStatusProvider().scan(context: ctx)
        let floodMs = (CFAbsoluteTimeGetCurrent() - tFloodStart) * 1000.0
        print(String(format: "  ✓ Scanned & parsed %d/100 synthetic tasks in %.2fms", dropInItems.count, floodMs))
        if dropInItems.count != 100 {
            print("  ✗ FAIL: Expected 100 tasks, got \(dropInItems.count)")
            allPassed = false
        }

        // Suite 3: Fuzzing & Corrupted Data Resilience (Malformed JSON, Truncated UTF-16LE, 5MB Log Tail)
        print("\n[Suite 3/4] Fuzzing & Corrupted Data Resilience (Malformed JSON + 5MB Log Tail)...")
        try? Data([0xFF, 0xFE, 0x00, 0x4E, 0x2D, 0x00, 0x80]).write(to: URL(fileURLWithPath: "\(tempDir)/corrupted.json"))
        try? "{bad_json: [1, 2, ".write(toFile: "\(tempDir)/broken.json", atomically: true, encoding: .utf8)
        let afterCorrupt = DropInStatusProvider().scan(context: ctx)
        let largeLogPath = "\(tempDir)/huge_session.jsonl"
        let sampleLine = "{\"kind\":\"event\",\"seq\":1,\"envelope\":{\"type\":\"turn.step.started\",\"payload\":{\"step\":99}}}\n"
        if let lineData = sampleLine.data(using: .utf8) {
            var bigData = Data(capacity: lineData.count * 60000)
            for _ in 0..<60000 { bigData.append(lineData) }
            try? bigData.write(to: URL(fileURLWithPath: largeLogPath))
        }
        let tTailStart = CFAbsoluteTimeGetCurrent()
        let tailReadOk = engine.stressTestTailRead(path: largeLogPath, maxBytes: 128 * 1024)
        let tailMs = (CFAbsoluteTimeGetCurrent() - tTailStart) * 1000.0
        print(String(format: "  ✓ Survived corrupted JSON files (%d valid tasks preserved) | ~5MB JSONL tail read in %.2fms", afterCorrupt.count, tailMs))
        if !tailReadOk || afterCorrupt.count != 100 || tailMs > 50.0 {
            print("  ✗ FAIL: Fuzzing or 5MB tail read failed")
            allPassed = false
        }

        // 尾部读取的起点落在中文（3 字节 UTF-8）字符中间时仍须读出内容：连续 3 个窗口大小中必有 2 个截在字符中间
        let cjkLogPath = "\(tempDir)/cjk_session.jsonl"
        try? (String(repeating: "中文转录", count: 1000) + "\n" + sampleLine).write(toFile: cjkLogPath, atomically: true, encoding: .utf8)
        let cjkTailOk = (UInt64(1000)...UInt64(1002)).allSatisfy { engine.stressTestTailRead(path: cjkLogPath, maxBytes: $0) }
        if cjkTailOk {
            print("  ✓ Tail read starting inside a multi-byte UTF-8 (CJK) character still decodes")
        } else {
            print("  ✗ FAIL: Tail read starting inside a multi-byte UTF-8 (CJK) character returned nil")
            allPassed = false
        }

        // Suite 4: Notification Anti-Spam State Machine Verification
        print("\n[Suite 4/4] Notification Anti-Spam State Machine Verification (200 rapid frames)...")
        let alertCheckPassed = engine.stressTestNotificationAntiSpam()
        if alertCheckPassed {
            print("  ✓ 200 rapid CPU/duplicate frames -> 0 false alerts | 1 genuine completion -> 1 exact alert | Cooldown -> 0 spam alerts")
        } else {
            print("  ✗ FAIL: Notification anti-spam state machine check failed")
            allPassed = false
        }

        print("====================================================================")
        print(allPassed ? "✅ ALL 4 STRESS TEST SUITES PASSED!" : "❌ SOME STRESS TESTS FAILED")
        print("====================================================================")
        return allPassed
    }
}
