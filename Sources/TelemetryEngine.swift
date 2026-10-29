import Cocoa
import Combine
import SQLite3

final class TelemetryEngine: ObservableObject {
    @Published var tasks: [AITaskItem] = []
    @Published var activeAlert: CompletionAlert? = nil
    @Published var recentAlerts: [CompletionAlert] = []

    // 提醒偏好设置（默认关闭系统通知轰炸，仅使用悬浮窗内横幅 + 轻柔提示音 + 前台应用免打扰）
    @Published var soundEnabled: Bool = true
    @Published var voiceEnabled: Bool = false
    @Published var systemBannerEnabled: Bool = false {
        didSet {
            if systemBannerEnabled {
                WindowActivator.shared.requestNotificationPermissionIfNeeded()
            }
        }
    }
    @Published var muteFrontmostApp: Bool = true
    @Published var doNotDisturbEnabled: Bool = false
    @Published var lastScanTime: Date = Date()

    private var timer: Timer?
    private var alertAutoDismissWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.aipulse.telemetry", qos: .utility)

    // 防抖与防轰炸状态追踪
    private var previousStatuses: [String: TaskStatus] = [:]
    private var runningStartTimes: [String: Date] = [:]
    private var notifiedSignatures: [String: String] = [:]
    private var lastAlertTimeByApp: [String: Date] = [:]
    private var recentCompletionTimestamps: [String: Date] = [:]
    private var isFirstScan = true
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    init(autoStart: Bool = true) {
        if autoStart {
            startMonitoring()
        }
    }

    func startMonitoring() {
        scanNow()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanNow()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// 供命令行自检 (--self-test) 同步返回所有检测到的 AI 任务列表
    func performSynchronousSelfTest() -> [AITaskItem] {
        let runningAppsSnapshot = NSWorkspace.shared.runningApplications.map { app in
            RunningAppInfo(
                bundleId: app.bundleIdentifier ?? "",
                name: app.localizedName ?? "",
                pid: app.processIdentifier,
                appPath: app.bundleURL?.path ?? ""
            )
        }
        var items = performFullScan(runningApps: runningAppsSnapshot)
        items.sort { a, b in
            if a.status.sortPriority != b.status.sortPriority {
                return a.status.sortPriority < b.status.sortPriority
            }
            if a.isAppRunning != b.isAppRunning {
                return a.isAppRunning
            }
            return a.updatedAt > b.updatedAt
        }
        return items
    }

    func scanNow() {
        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let runningAppsSnapshot = NSWorkspace.shared.runningApplications.map { app in
            RunningAppInfo(
                bundleId: app.bundleIdentifier ?? "",
                name: app.localizedName ?? "",
                pid: app.processIdentifier,
                appPath: app.bundleURL?.path ?? ""
            )
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            let scanned = self.performFullScan(runningApps: runningAppsSnapshot)
            DispatchQueue.main.async {
                self.processScannedTasks(scanned, frontmostBundleId: frontmostBundleId)
                self.lastScanTime = Date()
            }
        }
    }

    /// 模拟触发一次任务完成提醒（供用户手动测试弹窗、音效、语音及一键跳转）
    func simulateCompletionAlert() {
        let targetTask = tasks.first(where: { $0.isAppRunning }) ?? tasks.first
        let appName = targetTask?.appName ?? "Kimi Code"
        let bundleId = targetTask?.bundleId ?? "com.kimi.code.desktop"
        let appPath = targetTask?.appPath ?? "/Applications/Kimi Code.app"
        let workspace = targetTask?.workspace ?? "kimi"
        let title = targetTask?.taskTitle ?? "已完成当前 AI 编程任务"

        let alert = CompletionAlert(
            taskId: targetTask?.id ?? "sim-task",
            appName: appName,
            bundleId: bundleId,
            appPath: appPath,
            workspace: workspace,
            taskTitle: title,
            status: .completed,
            timestamp: Date()
        )

        showInPanelAlert(alert)
        WindowActivator.shared.triggerAlert(
            alert: alert,
            soundEnabled: self.soundEnabled,
            voiceEnabled: self.voiceEnabled,
            systemBannerEnabled: self.systemBannerEnabled
        )
    }

    /// 一键清除所有卡片上的“刚刚完成”闪烁高亮与顶部横幅
    func clearCompletedHighlights() {
        recentCompletionTimestamps.removeAll()
        activeAlert = nil
        tasks = tasks.map { item in
            var copy = item
            copy.justCompleted = false
            return copy
        }
    }

    private func showInPanelAlert(_ alert: CompletionAlert) {
        self.activeAlert = alert
        self.recentAlerts.insert(alert, at: 0)
        if self.recentAlerts.count > 15 {
            self.recentAlerts.removeLast()
        }

        alertAutoDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.activeAlert?.id == alert.id {
                self.activeAlert = nil
            }
        }
        alertAutoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work)
    }

    private func processScannedTasks(_ newTasks: [AITaskItem], frontmostBundleId: String) {
        var updatedList: [AITaskItem] = []
        let now = Date()

        for var item in newTasks {
            if isFirstScan {
                previousStatuses[item.id] = item.status
                if !item.completionSignature.isEmpty && (item.status == .completed || item.status == .waiting) {
                    notifiedSignatures[item.id] = item.completionSignature
                }
                if item.status == .running {
                    runningStartTimes[item.id] = item.startedAt ?? now
                    item.startedAt = runningStartTimes[item.id]
                }
                updatedList.append(item)
                continue
            }

            let prevStatus = previousStatuses[item.id]

            if item.status == .running {
                if runningStartTimes[item.id] == nil {
                    runningStartTimes[item.id] = item.startedAt ?? now
                }
                item.startedAt = runningStartTimes[item.id]
            }

            if prevStatus == .running && (item.status == .completed || item.status == .waiting) {
                let runDuration = runningStartTimes[item.id].map { now.timeIntervalSince($0) } ?? 0
                runningStartTimes[item.id] = nil

                let alreadyNotifiedSameTurn = (!item.completionSignature.isEmpty && notifiedSignatures[item.id] == item.completionSignature)
                let appCooldownElapsed = lastAlertTimeByApp[item.bundleId].map { now.timeIntervalSince($0) >= 30.0 } ?? true
                let isUserCurrentlyInThatApp = (muteFrontmostApp && frontmostBundleId == item.bundleId)

                if item.canTriggerAlert && runDuration >= 6.0 && !alreadyNotifiedSameTurn && appCooldownElapsed {
                    if !item.completionSignature.isEmpty {
                        notifiedSignatures[item.id] = item.completionSignature
                    }
                    lastAlertTimeByApp[item.bundleId] = now
                    recentCompletionTimestamps[item.id] = now

                    if !isUserCurrentlyInThatApp && !doNotDisturbEnabled {
                        let alert = CompletionAlert(
                            taskId: item.id,
                            appName: item.appName,
                            bundleId: item.bundleId,
                            appPath: item.appPath,
                            workspace: item.workspace,
                            taskTitle: item.taskTitle,
                            status: item.status,
                            timestamp: now
                        )
                        showInPanelAlert(alert)
                        WindowActivator.shared.triggerAlert(
                            alert: alert,
                            soundEnabled: self.soundEnabled,
                            voiceEnabled: self.voiceEnabled,
                            systemBannerEnabled: self.systemBannerEnabled
                        )
                    }
                }
            } else if item.status != .running {
                runningStartTimes[item.id] = nil
                if !item.completionSignature.isEmpty && (item.status == .completed || item.status == .waiting) {
                    notifiedSignatures[item.id] = item.completionSignature
                }
            }

            if let compTime = recentCompletionTimestamps[item.id],
               now.timeIntervalSince(compTime) < 35,
               (item.status == .completed || item.status == .waiting) {
                item.justCompleted = true
            }

            previousStatuses[item.id] = item.status
            updatedList.append(item)
        }

        isFirstScan = false

        updatedList.sort { a, b in
            if a.justCompleted != b.justCompleted {
                return a.justCompleted
            }
            if a.status.sortPriority != b.status.sortPriority {
                return a.status.sortPriority < b.status.sortPriority
            }
            if a.isAppRunning != b.isAppRunning {
                return a.isAppRunning
            }
            return a.updatedAt > b.updatedAt
        }

        self.tasks = updatedList
    }

    // MARK: - Core Scan Pipeline

    private struct RunningAppInfo {
        let bundleId: String
        let name: String
        let pid: Int32
        let appPath: String
    }

    private struct ProcessMetrics {
        var cpuByKeyword: [String: Double] = [:]
        var cliTasks: [(pid: Int, tty: String, cpu: Double, cmd: String)] = []
    }

    private func performFullScan(runningApps: [RunningAppInfo]) -> [AITaskItem] {
        let procMetrics = collectProcessMetrics()
        var results: [AITaskItem] = []

        // 0. 开放插件与 Provider 注册表（包含 DeepSeek、Grok Bot、~/.ai-pulse/status 与 ~/.ai-pulse/plugins）
        let scanCtx = TelemetryScanContext(
            homeDir: homeDir,
            runningBundleIds: Set(runningApps.map { $0.bundleId }),
            cpuByKeyword: procMetrics.cpuByKeyword,
            statusDirOverride: nil,
            pluginsDirOverride: nil
        )
        results.append(contentsOf: ProviderRegistry.shared.scanAll(context: scanCtx))

        // 1. Antigravity
        results.append(contentsOf: scanAntigravity(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["antigravity"] ?? 0))

        // 2. ChatGPT / Codex
        results.append(contentsOf: scanCodex(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["codex"] ?? 0))

        // 3. Kimi Code
        results.append(contentsOf: scanKimiCode(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["kimi"] ?? 0))

        // 4. WorkBuddy
        results.append(contentsOf: scanWorkBuddy(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["workbuddy"] ?? 0))

        // 5. Manus Studio
        results.append(contentsOf: scanManusStudio(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["manus"] ?? 0))

        // 6. Cursor (Composer + Cloud Agents)
        results.append(contentsOf: scanCursor(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["cursor"] ?? 0))

        // 7. OpenCode
        results.append(contentsOf: scanOpenCode(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["opencode"] ?? 0))

        // 8. Claude Desktop & Claude Code
        results.append(contentsOf: scanClaude(runningApps: runningApps, cpu: procMetrics.cpuByKeyword["claude"] ?? 0))

        // 9. 其他正在运行的 AI IDE
        results.append(contentsOf: scanOtherIDEs(runningApps: runningApps, procMetrics: procMetrics))

        // 10. 终端独立 CLI Agent 进程
        results.append(contentsOf: scanTerminalCLITasks(cliList: procMetrics.cliTasks))

        return results
    }

    // MARK: - 0. Process CPU & CLI Snapshot

    private func collectProcessMetrics() -> ProcessMetrics {
        var metrics = ProcessMetrics()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,pcpu=,tty=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return metrics }

            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 4 else { continue }
                let pid = Int(parts[0]) ?? 0
                let cpu = Double(parts[1]) ?? 0.0
                let tty = String(parts[2])
                let comm = String(parts[3])
                let lower = comm.lowercased()

                if lower.contains("antigravity") || lower.contains("language_server") {
                    metrics.cpuByKeyword["antigravity", default: 0] += cpu
                }
                if lower.contains("cursor") {
                    metrics.cpuByKeyword["cursor", default: 0] += cpu
                }
                if lower.contains("opencode") {
                    metrics.cpuByKeyword["opencode", default: 0] += cpu
                }
                if lower.contains("chatgpt") || lower.contains("codex") {
                    metrics.cpuByKeyword["codex", default: 0] += cpu
                }
                if lower.contains("claude") {
                    metrics.cpuByKeyword["claude", default: 0] += cpu
                }
                if lower.contains("kimi") {
                    metrics.cpuByKeyword["kimi", default: 0] += cpu
                }
                if lower.contains("workbuddy") {
                    metrics.cpuByKeyword["workbuddy", default: 0] += cpu
                }
                if lower.contains("manus") {
                    metrics.cpuByKeyword["manus", default: 0] += cpu
                }
                if lower.contains("deepseek") || lower.contains("dsh") {
                    metrics.cpuByKeyword["deepseek", default: 0] += cpu
                }
                if lower.contains("grok") || lower.contains("sand") {
                    metrics.cpuByKeyword["grok", default: 0] += cpu
                }
                if lower.contains("trae") {
                    metrics.cpuByKeyword["trae", default: 0] += cpu
                }
                if lower.contains("codebuddy") {
                    metrics.cpuByKeyword["codebuddy", default: 0] += cpu
                }
                if lower.contains("visual studio code") || lower.contains("code helper") || lower.contains("copilot") {
                    metrics.cpuByKeyword["vscode", default: 0] += cpu
                }

                if tty != "??" && tty.hasPrefix("ttys") {
                    let baseName = (comm as NSString).lastPathComponent.lowercased()
                    if ["claude", "aider", "gemini", "kimi", "codex", "opencode"].contains(baseName) {
                        metrics.cliTasks.append((pid: pid, tty: tty, cpu: cpu, cmd: baseName))
                    }
                }
            }
        } catch {
            return metrics
        }
        return metrics
    }

    // MARK: - 1. Antigravity Scanner

    private func scanAntigravity(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "com.google.antigravity"
        let appPath = "/Applications/Antigravity.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId })
        let brainPath = "\(homeDir)/.gemini/antigravity/brain"

        var items: [AITaskItem] = []
        let fm = FileManager.default

        if let convDirs = try? fm.contentsOfDirectory(atPath: brainPath) {
            var dirInfos: [(id: String, transcriptPath: String, modDate: Date)] = []
            for dir in convDirs {
                if dir.hasPrefix(".") { continue }
                let tPath = "\(brainPath)/\(dir)/.system_generated/logs/transcript.jsonl"
                if let attrs = try? fm.attributesOfItem(atPath: tPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    dirInfos.append((id: dir, transcriptPath: tPath, modDate: modDate))
                }
            }
            dirInfos.sort { $0.modDate > $1.modDate }

            for info in dirInfos.prefix(1) {
                guard let tailText = readFileTail(path: info.transcriptPath, maxBytes: 256 * 1024) else { continue }
                let lines = tailText.split(separator: "\n")

                var userPrompt = ""
                var workspaceName = "Antigravity"
                var fullWorkspace = ""
                var lastStepIndex = -1
                var lastType = ""
                var lastStatus = ""
                var lastToolNames: [String] = []

                for line in lines {
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let type = json["type"] as? String ?? ""
                    let status = json["status"] as? String ?? ""
                    let stepIdx = json["step_index"] as? Int ?? lastStepIndex

                    if type == "USER_INPUT", let content = json["content"] as? String {
                        if let extracted = extractBetween(content, start: "<USER_REQUEST>", end: "</USER_REQUEST>") {
                            let clean = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "\n", with: " ")
                            if !clean.isEmpty {
                                userPrompt = String(clean.prefix(65))
                            }
                        }
                        if fullWorkspace.isEmpty,
                           let ws = extractBetween(content, start: "Command Working Directory: ", end: "\n") {
                            fullWorkspace = ws.trimmingCharacters(in: .whitespacesAndNewlines)
                            workspaceName = (fullWorkspace as NSString).lastPathComponent
                        }
                    }

                    lastStepIndex = stepIdx
                    lastType = type
                    lastStatus = status
                    if let toolCalls = json["tool_calls"] as? [[String: Any]] {
                        lastToolNames = toolCalls.compactMap { $0["name"] as? String }
                    } else {
                        lastToolNames = []
                    }
                }

                guard !lastType.isEmpty else { continue }

                if userPrompt.isEmpty {
                    userPrompt = "Antigravity 会话 (\(info.id.prefix(8)))"
                }

                let ageSeconds = Date().timeIntervalSince(info.modDate)
                let taskStatus: TaskStatus
                let detail: String
                let signature: String

                if lastType == "PLANNER_RESPONSE" && lastToolNames.contains("ask_question") {
                    taskStatus = .waiting
                    detail = "等待您回答多选问题 (ask_question)"
                    signature = "ag-\(info.id)-wait-\(lastStepIndex)"
                } else if lastType == "PLANNER_RESPONSE" && lastStatus == "DONE" && lastToolNames.isEmpty {
                    taskStatus = .completed
                    detail = "已完成本轮任务响应 (Step \(lastStepIndex))"
                    signature = "ag-\(info.id)-done-\(lastStepIndex)"
                } else if ageSeconds < 180 && isRunning {
                    taskStatus = .running
                    if !lastToolNames.isEmpty {
                        detail = "Step \(lastStepIndex) · 正在调用: \(lastToolNames.joined(separator: ", "))"
                    } else {
                        detail = "Step \(lastStepIndex) · Agent 正在思考与执行..."
                    }
                    signature = ""
                } else {
                    taskStatus = .completed
                    detail = "任务已结束就绪"
                    signature = "ag-\(info.id)-done-\(lastStepIndex)"
                }

                items.append(AITaskItem(
                    id: "antigravity-\(info.id)",
                    appName: "Antigravity",
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .ide,
                    taskTitle: userPrompt,
                    workspace: workspaceName,
                    fullWorkspacePath: fullWorkspace,
                    statusDetail: detail,
                    modelName: "Gemini 4 Argon",
                    status: taskStatus,
                    cpuPercent: cpu,
                    updatedAt: info.modDate,
                    isAppRunning: isRunning,
                    completionSignature: signature,
                    canTriggerAlert: true
                ))
            }
        }

        return items
    }

    // MARK: - 2. ChatGPT / Codex Scanner

    private func scanCodex(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "com.openai.codex"
        let appPath = "/Applications/ChatGPT.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId }) || cpu > 0.1
        let stateDbPath = "\(homeDir)/.codex/state_5.sqlite"
        let historyDbPath = "\(homeDir)/.codex/thread_history_1.sqlite"

        var items: [AITaskItem] = []
        guard let stateDb = openReadOnlySQLite(path: stateDbPath) else { return items }
        defer { sqlite3_close(stateDb) }

        let historyDb = openReadOnlySQLite(path: historyDbPath)
        defer {
            if let hdb = historyDb {
                sqlite3_close(hdb)
            }
        }

        let sql = """
        SELECT id, title, first_user_message, cwd, IFNULL(model, 'codex'), updated_at, rollout_path
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at DESC
        LIMIT 2;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(stateDb, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tid = columnString(stmt, 0)
                let title = columnString(stmt, 1)
                let firstMsg = columnString(stmt, 2)
                let cwd = columnString(stmt, 3)
                let model = columnString(stmt, 4)
                let updatedSec = sqlite3_column_int64(stmt, 5)
                let rolloutPath = columnString(stmt, 6)

                var displayTitle: String
                if !title.isEmpty {
                    displayTitle = String(title.replacingOccurrences(of: "\n", with: " ").prefix(60))
                } else if !firstMsg.isEmpty {
                    displayTitle = String(firstMsg.replacingOccurrences(of: "\n", with: " ").prefix(60))
                } else {
                    displayTitle = "ChatGPT / Codex 会话"
                }

                var updatedDate = Date(timeIntervalSince1970: TimeInterval(updatedSec))
                var startedDate: Date? = nil
                if let attrs = try? FileManager.default.attributesOfItem(atPath: rolloutPath),
                   let fileMod = attrs[.modificationDate] as? Date,
                   fileMod > updatedDate {
                    updatedDate = fileMod
                }

                var status: TaskStatus = .completed
                var detail = "Codex 任务已完成"
                var sig = "codex-done-\(tid)-\(updatedSec)"
                var resolvedFromHistoryDb = false

                if let hdb = historyDb {
                    let turnSql = """
                    SELECT turn_id, status, IFNULL(started_at, 0), IFNULL(completed_at, 0)
                    FROM thread_turns
                    WHERE thread_id = '\(tid)'
                    ORDER BY rollout_ordinal DESC
                    LIMIT 1;
                    """
                    var turnStmt: OpaquePointer?
                    if sqlite3_prepare_v2(hdb, turnSql, -1, &turnStmt, nil) == SQLITE_OK {
                        defer { sqlite3_finalize(turnStmt) }
                        if sqlite3_step(turnStmt) == SQLITE_ROW {
                            let turnId = columnString(turnStmt, 0)
                            let turnStatus = columnString(turnStmt, 1)
                            let startedAt = sqlite3_column_int64(turnStmt, 2)
                            let completedAt = sqlite3_column_int64(turnStmt, 3)
                            resolvedFromHistoryDb = true

                            if startedAt > 0 {
                                let startD = Date(timeIntervalSince1970: TimeInterval(startedAt))
                                startedDate = startD
                                if startD > updatedDate { updatedDate = startD }
                            }
                            if completedAt > 0 {
                                let compD = Date(timeIntervalSince1970: TimeInterval(completedAt))
                                if compD > updatedDate { updatedDate = compD }
                            }

                            var latestItemType = ""
                            let itemSql = """
                            SELECT item_type, item_json
                            FROM thread_items
                            WHERE thread_id = '\(tid)' AND turn_id = '\(turnId)'
                            ORDER BY rollout_ordinal DESC
                            LIMIT 8;
                            """
                            var itemStmt: OpaquePointer?
                            if sqlite3_prepare_v2(hdb, itemSql, -1, &itemStmt, nil) == SQLITE_OK {
                                defer { sqlite3_finalize(itemStmt) }
                                while sqlite3_step(itemStmt) == SQLITE_ROW {
                                    let iType = columnString(itemStmt, 0)
                                    let iJson = columnString(itemStmt, 1)
                                    if latestItemType.isEmpty {
                                        latestItemType = iType
                                    }
                                    if iType == "userMessage",
                                       let data = iJson.data(using: .utf8),
                                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       let contentArr = obj["content"] as? [[String: Any]],
                                       let firstText = contentArr.first?["text"] as? String {
                                        let cleanPrompt = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .replacingOccurrences(of: "\n", with: " ")
                                        if !cleanPrompt.isEmpty {
                                            displayTitle = String(cleanPrompt.prefix(62))
                                        }
                                        break
                                    }
                                }
                            }

                            if turnStatus == "inProgress" || (completedAt == 0 && turnStatus != "completed" && turnStatus != "interrupted" && turnStatus != "failed") {
                                status = .running
                                switch latestItemType {
                                case "commandExecution":
                                    detail = "正在执行终端命令 (commandExecution)..."
                                case "mcpToolCall":
                                    detail = "正在调用 MCP 工具..."
                                case "reasoning":
                                    detail = "正在深度推理思考中..."
                                case "agentMessage":
                                    detail = "正在生成回复内容..."
                                default:
                                    detail = "正在执行本轮任务..."
                                }
                                sig = ""
                            } else {
                                status = .completed
                                detail = "Codex 任务已完成"
                                sig = "codex-done-\(tid)-\(turnId)"
                            }
                        }
                    }
                }

                if let tail = readFileTail(path: rolloutPath, maxBytes: 64 * 1024) {
                    let lines = tail.split(separator: "\n")
                    var lastEvent = ""
                    for line in lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        let topType = obj["type"] as? String ?? ""
                        if topType == "event_msg",
                           let payload = obj["payload"] as? [String: Any],
                           let evType = payload["type"] as? String {
                            lastEvent = evType
                        } else if topType == "response_item",
                                  let payload = obj["payload"] as? [String: Any],
                                  let pType = payload["type"] as? String {
                            lastEvent = pType
                        }
                    }

                    let age = Date().timeIntervalSince(updatedDate)
                    if ["exec_approval_request", "apply_patch_approval_request", "request_user_input"].contains(lastEvent) && age < 600 {
                        status = .waiting
                        detail = "等待批准终端命令或补丁操作"
                        sig = "codex-wait-\(tid)-\(Int(updatedDate.timeIntervalSince1970 / 15))"
                    } else if !resolvedFromHistoryDb {
                        if lastEvent != "task_complete" && lastEvent != "turn_aborted" && !lastEvent.isEmpty && age < 180 {
                            status = .running
                            detail = "Codex 正在执行中 (\(lastEvent))..."
                            sig = ""
                        }
                    }
                }

                let wsName = cwd.isEmpty ? "默认目录" : (cwd as NSString).lastPathComponent
                items.append(AITaskItem(
                    id: "codex-\(tid)",
                    appName: "ChatGPT / Codex",
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .desktop,
                    taskTitle: displayTitle,
                    workspace: wsName,
                    fullWorkspacePath: cwd,
                    statusDetail: detail,
                    modelName: model,
                    status: status,
                    cpuPercent: cpu,
                    updatedAt: updatedDate,
                    startedAt: startedDate,
                    isAppRunning: isRunning,
                    completionSignature: sig,
                    canTriggerAlert: true
                ))
            }
        }

        return items
    }

    // MARK: - 3. Kimi Code Scanner (~/.kimi-code/server/events/session_*.jsonl + state.json)

    private func scanKimiCode(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "com.kimi.code.desktop"
        let appPath = "/Applications/Kimi Code.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId }) || cpu > 0.1
        let kimiRoot = "\(homeDir)/.kimi-code"
        let indexPath = "\(kimiRoot)/session_index.jsonl"
        let eventsDir = "\(kimiRoot)/server/events"

        var items: [AITaskItem] = []
        let fm = FileManager.default

        var sessionMeta: [String: (sessionDir: String, workDir: String)] = [:]
        if let indexText = readFileTail(path: indexPath, maxBytes: 64 * 1024) {
            for line in indexText.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = obj["sessionId"] as? String else { continue }
                let sDir = obj["sessionDir"] as? String ?? ""
                let wDir = obj["workDir"] as? String ?? ""
                sessionMeta[sid] = (sDir, wDir)
            }
        }

        // 只关注真正的 Turn 生命周期事件，忽略 turn.ended 之后追加的 event.session.work_changed / context.spliced 等元数据事件
        let turnActiveEvents: Set<String> = [
            "turn.started", "prompt.started", "prompt.submitted",
            "turn.step.started", "turn.step.completed",
            "tool.call.started", "tool.result", "task.started"
        ]
        let turnDoneEvents: Set<String> = [
            "turn.ended", "prompt.completed", "compaction.completed"
        ]

        if let eventFiles = try? fm.contentsOfDirectory(atPath: eventsDir) {
            var fileInfos: [(sid: String, path: String, modDate: Date)] = []
            for file in eventFiles {
                guard file.hasPrefix("session_") && file.hasSuffix(".jsonl") else { continue }
                let sid = String(file.dropLast(6))
                let fullPath = "\(eventsDir)/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    fileInfos.append((sid: sid, path: fullPath, modDate: modDate))
                }
            }
            fileInfos.sort { $0.modDate > $1.modDate }

            for info in fileInfos.prefix(2) {
                let meta = sessionMeta[info.sid]
                var workDir = meta?.workDir ?? ""
                var displayTitle = "Kimi Code 会话"

                if let sDir = meta?.sessionDir, !sDir.isEmpty {
                    let statePath = "\(sDir)/state.json"
                    if let sData = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                       let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any] {
                        if let cwd = sJson["cwd"] as? String, !cwd.isEmpty {
                            workDir = cwd
                        }
                        let rawTitle = (sJson["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let lastPrompt = (sJson["lastPrompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                        if !rawTitle.isEmpty && rawTitle.lowercased() != "hi" && rawTitle != "New Session" {
                            displayTitle = String(rawTitle.replacingOccurrences(of: "\n", with: " ").prefix(62))
                        } else if !lastPrompt.isEmpty {
                            let clean = lastPrompt
                                .replacingOccurrences(of: "\n", with: " ")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            displayTitle = String(clean.prefix(62))
                        }
                    }
                }

                guard let tailText = readFileTail(path: info.path, maxBytes: 128 * 1024) else { continue }
                let lines = tailText.split(separator: "\n")

                var lastLifecycleSeq: Int = 0
                var lastLifecycleEvent: String = ""
                var lastStep: Int = 0
                var lastToolName: String = ""
                var lastToolDesc: String = ""
                var lastEndReason: String = ""
                var lastNotifyTitle: String = ""
                var lastSubstantivePrompt: String = ""
                var lastCompactionSummary: String = ""
                var workChangedMainActive: Bool?
                var workChangedPendingInteraction: String = "none"

                let genericPrompts: Set<String> = ["继续", "请继续", "请重新开始", "现在咋样了", "现在咋样啦", "hi", "ok", "好的"]

                for line in lines {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let env = obj["envelope"] as? [String: Any] else { continue }

                    let seq = obj["seq"] as? Int ?? (env["seq"] as? Int ?? lastLifecycleSeq)
                    let evType = env["type"] as? String ?? ""
                    let payload = env["payload"] as? [String: Any] ?? [:]

                    if let step = payload["step"] as? Int {
                        lastStep = step
                    }

                    if turnActiveEvents.contains(evType) || turnDoneEvents.contains(evType) {
                        lastLifecycleEvent = evType
                        lastLifecycleSeq = seq
                    }

                    if evType == "prompt.submitted",
                       let contentArr = payload["content"] as? [[String: Any]],
                       let firstText = contentArr.first?["text"] as? String {
                        let cleaned = firstText
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleaned.count >= 4 && !genericPrompts.contains(cleaned.lowercased()) {
                            lastSubstantivePrompt = String(cleaned.prefix(50))
                        }
                    } else if evType == "compaction.completed",
                              let res = payload["result"] as? [String: Any],
                              let summary = res["summary"] as? String {
                        let firstLine = summary.split(separator: "\n").first.map(String.init) ?? ""
                        if !firstLine.isEmpty {
                            lastCompactionSummary = String(firstLine.prefix(52))
                        }
                    } else if evType == "event.session.work_changed" {
                        if let mainActive = payload["main_turn_active"] as? Bool {
                            workChangedMainActive = mainActive
                        }
                        if let pending = payload["pending_interaction"] as? String {
                            workChangedPendingInteraction = pending
                        }
                    }

                    if evType == "tool.call.started" {
                        lastToolName = payload["name"] as? String ?? ""
                        lastToolDesc = payload["description"] as? String ?? ""
                        if lastToolName == "NotifyUser",
                           let args = payload["args"] as? [String: Any],
                           let nTitle = args["title"] as? String, !nTitle.isEmpty {
                            lastNotifyTitle = nTitle
                        }
                    } else if turnDoneEvents.contains(evType) {
                        lastEndReason = payload["reason"] as? String ?? "completed"
                        lastToolName = ""
                        lastToolDesc = ""
                    }
                }

                // 如果标题过短（如“继续”或“hi”），优先结合 NotifyUser 汇报标题、实质性 Prompt 或 Compaction 摘要提升可读性
                if displayTitle.count <= 6 || genericPrompts.contains(displayTitle.lowercased()) {
                    if !lastNotifyTitle.isEmpty {
                        displayTitle = "\(displayTitle) · \(lastNotifyTitle)"
                    } else if !lastSubstantivePrompt.isEmpty {
                        displayTitle = "\(displayTitle) · \(lastSubstantivePrompt)"
                    } else if !lastCompactionSummary.isEmpty {
                        displayTitle = String(lastCompactionSummary.prefix(58))
                    }
                }

                let ageSec = Date().timeIntervalSince(info.modDate)
                let status: TaskStatus
                let detail: String
                let sig: String

                if workChangedPendingInteraction != "none" && !workChangedPendingInteraction.isEmpty && ageSec < 600 {
                    status = .waiting
                    detail = "Kimi Code 等待您的确认 (\(workChangedPendingInteraction))"
                    sig = "kimi-wait-\(info.sid)-\(lastLifecycleSeq)"
                } else if turnDoneEvents.contains(lastLifecycleEvent) || workChangedMainActive == false {
                    if lastEndReason == "error" || lastEndReason == "failed" {
                        status = .error
                        detail = "Kimi Code 任务异常结束 (\(lastEndReason))"
                        sig = "kimi-err-\(info.sid)-\(lastLifecycleSeq)"
                    } else {
                        status = .completed
                        detail = lastStep > 0 ? "已完成本轮任务 (共 \(lastStep) 步)" : "Kimi Code 任务已完成"
                        sig = "kimi-done-\(info.sid)-\(lastLifecycleSeq)"
                    }
                } else if lastLifecycleEvent.contains("approval") || lastLifecycleEvent.contains("permission") {
                    status = .waiting
                    detail = "Kimi Code 等待您的确认或授权"
                    sig = "kimi-wait-\(info.sid)-\(lastLifecycleSeq)"
                } else if (turnActiveEvents.contains(lastLifecycleEvent) || workChangedMainActive == true) && ageSec < 300 && isRunning {
                    status = .running
                    let stepPrefix = lastStep > 0 ? "Step \(lastStep) · " : ""
                    if !lastToolDesc.isEmpty {
                        detail = "\(stepPrefix)\(lastToolDesc)"
                    } else if !lastToolName.isEmpty {
                        let friendlyTool: String
                        if lastToolName.contains("browser") {
                            friendlyTool = "内置浏览器自动化"
                        } else if lastToolName == "Bash" {
                            friendlyTool = "执行终端 Bash 命令"
                        } else if lastToolName == "NotifyUser" {
                            friendlyTool = "向用户汇报阶段进展"
                        } else {
                            friendlyTool = lastToolName
                        }
                        detail = "\(stepPrefix)正在调用: \(friendlyTool)"
                    } else {
                        detail = "\(stepPrefix)Kimi Code 正在思考与执行中..."
                    }
                    sig = ""
                } else {
                    status = .completed
                    detail = lastStep > 0 ? "会话已就绪 (上次执行 \(lastStep) 步)" : "Kimi Code 会话已就绪"
                    sig = "kimi-done-\(info.sid)-\(lastLifecycleSeq)"
                }

                let wsName = workDir.isEmpty ? "kimi" : (workDir as NSString).lastPathComponent
                items.append(AITaskItem(
                    id: "kimi-\(info.sid)",
                    appName: "Kimi Code",
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .ide,
                    taskTitle: displayTitle,
                    workspace: wsName,
                    fullWorkspacePath: workDir,
                    statusDetail: detail,
                    modelName: "Kimi k2.5",
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
                id: "kimi-code-app",
                appName: "Kimi Code",
                bundleId: bundleId,
                appPath: appPath,
                category: .ide,
                taskTitle: "Kimi Code 桌面端在线",
                workspace: "默认工作区",
                fullWorkspacePath: "",
                statusDetail: "等待新任务触发",
                modelName: "Kimi Code",
                status: .idle,
                cpuPercent: cpu,
                updatedAt: Date(),
                isAppRunning: true,
                completionSignature: "kimi-idle",
                canTriggerAlert: false
            ))
        }

        return items
    }

    // MARK: - 4. WorkBuddy Scanner (~/.workbuddy/workbuddy.db + ~/.workbuddy/sessions/*.json)

    private func scanWorkBuddy(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "com.tencent.workbuddy.mac"
        let appPath = "/Applications/WorkBuddy.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId }) || cpu > 0.1
        let dbPath = "\(homeDir)/.workbuddy/workbuddy.db"
        let sessionsDir = "\(homeDir)/.workbuddy/sessions"

        var items: [AITaskItem] = []
        let fm = FileManager.default

        // 1. 检查 ~/.workbuddy/sessions/*.json 中是否有非 prewarm 或 status == running/busy 的活跃 worker
        var activeWorkerSessionIds = Set<String>()
        if let sFiles = try? fm.contentsOfDirectory(atPath: sessionsDir) {
            for file in sFiles where file.hasSuffix(".json") {
                let p = "\(sessionsDir)/\(file)"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let kind = json["kind"] as? String ?? ""
                    let sid = json["sessionId"] as? String ?? ""
                    let meta = json["meta"] as? [String: Any] ?? [:]
                    let mStatus = (meta["status"] as? String ?? "idle").lowercased()
                    if (kind != "prewarm" && !sid.isEmpty && mStatus != "idle") || mStatus == "running" || mStatus == "busy" {
                        activeWorkerSessionIds.insert(sid)
                    }
                }
            }
        }

        // 2. 查询 ~/.workbuddy/workbuddy.db 的 sessions 表
        if let db = openReadOnlySQLite(path: dbPath) {
            defer { sqlite3_close(db) }
            let sql = """
            SELECT id, COALESCE(NULLIF(custom_title, ''), NULLIF(title, ''), 'WorkBuddy 会话'),
                   cwd, LOWER(IFNULL(status, 'completed')), IFNULL(model, 'auto'), updated_at, unread
            FROM sessions
            WHERE deleted_at IS NULL
            ORDER BY updated_at DESC
            LIMIT 2;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let sid = columnString(stmt, 0)
                    let rawTitle = columnString(stmt, 1)
                    let cwd = columnString(stmt, 2)
                    let rawStatus = columnString(stmt, 3)
                    let model = columnString(stmt, 4)
                    let updatedMs = sqlite3_column_int64(stmt, 5)
                    let unread = sqlite3_column_int(stmt, 6)

                    let updatedDate = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
                    let ageSec = Date().timeIntervalSince(updatedDate)
                    let cleanTitle = String(rawTitle.replacingOccurrences(of: "\n", with: " ").prefix(62))
                    let wsName = cwd.isEmpty ? "WorkBuddy" : (cwd as NSString).lastPathComponent

                    let status: TaskStatus
                    let detail: String
                    let sig: String

                    if activeWorkerSessionIds.contains(sid) || (["running", "in_progress", "streaming", "working"].contains(rawStatus) && ageSec < 600 && isRunning) {
                        status = .running
                        detail = "WorkBuddy Agent 正在执行任务..."
                        sig = ""
                    } else if ["waiting", "pending", "approval"].contains(rawStatus) && ageSec < 600 {
                        status = .waiting
                        detail = "WorkBuddy 等待您的确认或输入"
                        sig = "wb-wait-\(sid)-\(updatedMs)"
                    } else if ["error", "failed"].contains(rawStatus) && ageSec < 3600 {
                        status = .error
                        detail = "任务执行异常 (\(rawStatus))"
                        sig = "wb-err-\(sid)-\(updatedMs)"
                    } else {
                        status = .completed
                        detail = unread > 0 ? "任务已完成（有未读结果）" : "WorkBuddy 任务已完成"
                        sig = "wb-done-\(sid)-\(updatedMs)"
                    }

                    items.append(AITaskItem(
                        id: "workbuddy-\(sid)",
                        appName: "WorkBuddy",
                        bundleId: bundleId,
                        appPath: appPath,
                        category: .desktop,
                        taskTitle: cleanTitle,
                        workspace: wsName,
                        fullWorkspacePath: cwd,
                        statusDetail: detail,
                        modelName: model,
                        status: status,
                        cpuPercent: cpu,
                        updatedAt: updatedDate,
                        isAppRunning: isRunning,
                        completionSignature: sig,
                        canTriggerAlert: true
                    ))
                }
            }
        }

        if items.isEmpty && isRunning {
            items.append(AITaskItem(
                id: "workbuddy-app",
                appName: "WorkBuddy",
                bundleId: bundleId,
                appPath: appPath,
                category: .desktop,
                taskTitle: "WorkBuddy 桌面端在线",
                workspace: "默认工作区",
                fullWorkspacePath: "",
                statusDetail: "等待新任务触发",
                modelName: "WorkBuddy",
                status: .idle,
                cpuPercent: cpu,
                updatedAt: Date(),
                isAppRunning: true,
                completionSignature: "wb-idle",
                canTriggerAlert: false
            ))
        }

        return items
    }

    // MARK: - 5. Manus Studio Scanner (IndexedDB UTF-16LE + operator.log)

    private func scanManusStudio(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "im.manus.desktop"
        let appPath = "/Applications/Manus Studio.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId }) || cpu > 0.1
        let manusSupport = "\(homeDir)/Library/Application Support/Manus"
        let idbDir = "\(manusSupport)/IndexedDB/app_manus_0.indexeddb.leveldb"
        let operatorLogPath = "\(manusSupport)/logs/operator.log"

        var items: [AITaskItem] = []
        let fm = FileManager.default

        // 1. 解析 operator.log 尾部：检查是否有未结束的 terminal run 或活跃本地会话
        var hasRunningLocalTerminal = false
        var activeLocalSessionsCount = 0
        var latestLogModDate = Date.distantPast

        if let attrs = try? fm.attributesOfItem(atPath: operatorLogPath),
           let modD = attrs[.modificationDate] as? Date {
            latestLogModDate = modD
        }

        if let opTail = readFileTail(path: operatorLogPath, maxBytes: 48 * 1024) {
            var runningActions = Set<String>()
            for line in opTail.split(separator: "\n") {
                let s = String(line)
                if s.contains("terminal run action="),
                   let act = extractBetween(s, start: "terminal run action=", end: " ") {
                    runningActions.insert(act)
                } else if s.contains("terminal finish action="),
                          let act = extractBetween(s, start: "terminal finish action=", end: " ") {
                    runningActions.remove(act)
                } else if s.contains("Received device_config"),
                          let sessPart = extractBetween(s, start: "folder(s), ", end: " session(s)"),
                          let cnt = Int(sessPart.trimmingCharacters(in: .whitespaces)) {
                    activeLocalSessionsCount = cnt
                }
            }
            if !runningActions.isEmpty && Date().timeIntervalSince(latestLogModDate) < 300 {
                hasRunningLocalTerminal = true
            }
        }

        // 2. 解析 IndexedDB 最新 .log 文件中的 V8 UTF-16LE 任务标题与完成状态
        var latestIdbModDate = latestLogModDate
        var extractedPhrases: [String] = []

        if let idbFiles = try? fm.contentsOfDirectory(atPath: idbDir) {
            let logFiles = idbFiles.filter { $0.hasSuffix(".log") }.sorted()
            if let latestLog = logFiles.last {
                let fullIdbLog = "\(idbDir)/\(latestLog)"
                if let attrs = try? fm.attributesOfItem(atPath: fullIdbLog),
                   let modD = attrs[.modificationDate] as? Date {
                    if modD > latestIdbModDate {
                        latestIdbModDate = modD
                    }
                }
                if let handle = FileHandle(forReadingAtPath: fullIdbLog) {
                    defer { try? handle.close() }
                    if let end = try? handle.seekToEnd() {
                        let startOff = end > 131072 ? (end - 131072) : 0
                        try? handle.seek(toOffset: startOff)
                        let rawData = handle.readDataToEndOfFile()
                        extractedPhrases = extractV8UTF16CJKStrings(from: rawData)
                    }
                }
            }
        }

        // 过滤出有意义的任务描述与最新状态标记
        var taskTitle = "Manus Studio 智能体任务"
        var latestStepBrief = ""
        var sawCompletedMarker = false
        var sawWaitingMarker = false
        var sawRunningMarker = false

        let statusSystemPhrases = [
            "已完成当前任务",
            "正在等待您的回复",
            "将在您回复后继续工作",
            "正在处理您的请求",
            "正在处理文件读取问题",
            "处理终端问题",
            "本地体验与重启说明"
        ]

        for phrase in extractedPhrases {
            if phrase.contains("已完成当前任务") || phrase.contains("准备好接收新请求") {
                sawCompletedMarker = true
                sawWaitingMarker = false
                sawRunningMarker = false
            } else if phrase.contains("正在等待您的回复") || phrase.contains("将在您回复后继续工作") {
                sawWaitingMarker = true
                sawCompletedMarker = false
                sawRunningMarker = false
            } else if phrase.contains("正在处理") || phrase.contains("处理终端问题") {
                sawRunningMarker = true
                latestStepBrief = phrase
            } else if phrase.count >= 8 && !statusSystemPhrases.contains(where: { phrase.contains($0) }) {
                latestStepBrief = taskTitle
                taskTitle = String(phrase.prefix(62))
            }
        }

        let ageSec = Date().timeIntervalSince(latestIdbModDate)
        let isActivelyWorking = isRunning && (hasRunningLocalTerminal || (sawRunningMarker && !sawCompletedMarker && ageSec < 120) || (activeLocalSessionsCount > 0 && ageSec < 45))

        if isRunning || !extractedPhrases.isEmpty {
            let status: TaskStatus
            let detail: String
            let sig: String
            let modBucket = Int(latestIdbModDate.timeIntervalSince1970 / 30)

            if isActivelyWorking {
                status = .running
                if hasRunningLocalTerminal {
                    detail = "Manus 正在本机终端执行命令..."
                } else if !latestStepBrief.isEmpty && latestStepBrief != "Manus Studio 智能体任务" {
                    detail = "正在执行: \(latestStepBrief.prefix(38))"
                } else {
                    detail = "Manus Agent 正在规划与执行任务..."
                }
                sig = ""
            } else if sawWaitingMarker && !sawCompletedMarker && ageSec < 1800 {
                status = .waiting
                detail = "Manus 正在等待您的回复或确认"
                sig = "manus-wait-\(modBucket)"
            } else {
                status = .completed
                detail = sawCompletedMarker ? "Manus 已完成当前任务，随时待命" : "Manus Studio 任务已就绪"
                sig = "manus-done-\(modBucket)"
            }

            items.append(AITaskItem(
                id: "manus-studio-main",
                appName: "Manus Studio",
                bundleId: bundleId,
                appPath: appPath,
                category: .desktop,
                taskTitle: taskTitle,
                workspace: "Manus 云端/本机协同",
                fullWorkspacePath: "\(homeDir)/Documents/Manus",
                statusDetail: detail,
                modelName: "Manus Agent",
                status: status,
                cpuPercent: cpu,
                updatedAt: latestIdbModDate == Date.distantPast ? Date() : latestIdbModDate,
                isAppRunning: isRunning,
                completionSignature: sig,
                canTriggerAlert: true
            ))
        }

        return items
    }

    /// 从 Chromium V8 IndexedDB 二进制日志中按真实字节偏移顺序提取双字节 UTF-16LE 中文句子
    private func extractV8UTF16CJKStrings(from data: Data) -> [String] {
        var positioned: [(pos: Int, text: String)] = []
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return [] }

        for offset in 0...1 {
            var chars: [Character] = []
            var startPos = offset
            var hi80Count = 0
            var cjkCount = 0
            var i = offset
            while i < bytes.count - 1 {
                let lo = bytes[i]
                let hi = bytes[i + 1]
                let cp = UInt16(lo) | (UInt16(hi) << 8)

                let isCJK = (0x4E00...0x9FFF).contains(cp)
                let isAsciiU16 = (hi == 0 && (0x20...0x7E).contains(lo)) && cjkCount > 0
                let isPunct = (0x3000...0x303F).contains(cp) || (0xFF01...0xFF5E).contains(cp)

                if isCJK || isAsciiU16 || isPunct {
                    if let scalar = UnicodeScalar(cp) {
                        if chars.isEmpty { startPos = i }
                        chars.append(Character(scalar))
                        if isCJK {
                            cjkCount += 1
                            if lo >= 0x80 || hi >= 0x80 {
                                hi80Count += 1
                            }
                        }
                    }
                } else {
                    if chars.count >= 6 && cjkCount >= 5 && hi80Count >= 3 {
                        let str = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !str.isEmpty {
                            positioned.append((pos: startPos, text: str))
                        }
                    }
                    chars.removeAll(keepingCapacity: true)
                    hi80Count = 0
                    cjkCount = 0
                }
                i += 2
            }
        }
        positioned.sort { $0.pos < $1.pos }
        return positioned.map { $0.text }
    }

    // MARK: - 6. Cursor Scanner

    private func scanCursor(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "com.todesktop.230313mzl4w4u92"
        let appPath = "/Applications/Cursor.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId })
        let stateDbPath = "\(homeDir)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        let convDbPath = "\(homeDir)/Library/Application Support/Cursor/User/globalStorage/conversation-search.db"

        var items: [AITaskItem] = []

        var latestTitles: [String: (title: String, updatedAt: Date)] = [:]
        if let db = openReadOnlySQLite(path: convDbPath) {
            defer { sqlite3_close(db) }
            let sql = "SELECT id, title, updated_at FROM conversations WHERE is_archived = 0 ORDER BY updated_at DESC LIMIT 5;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let cid = columnString(stmt, 0)
                    let title = columnString(stmt, 1)
                    let updatedMs = sqlite3_column_int64(stmt, 2)
                    let date = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
                    if !cid.isEmpty && !title.isEmpty {
                        latestTitles[cid] = (title, date)
                    }
                }
            }
        }

        if let db = openReadOnlySQLite(path: stateDbPath) {
            defer { sqlite3_close(db) }

            let composerSql = "SELECT composerId, lastUpdatedAt, value FROM composerHeaders ORDER BY lastUpdatedAt DESC LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, composerSql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let cid = columnString(stmt, 0)
                    let updatedMs = sqlite3_column_int64(stmt, 1)
                    let valStr = columnString(stmt, 2)
                    if let data = valStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let nameFromHeader = json["name"] as? String ?? ""
                        let hasBlocking = json["hasBlockingPendingActions"] as? Bool ?? false

                        var workspaceName = "Cursor 工作区"
                        if let draftTarget = json["draftTarget"] as? [String: Any],
                           let env = draftTarget["environment"] as? [String: Any],
                           let envName = env["logicalEnvironmentName"] as? String ?? env["name"] as? String,
                           !envName.isEmpty {
                            workspaceName = envName
                        }

                        var isGeneratingInDb = false
                        let kvSql = "SELECT value FROM cursorDiskKV WHERE key = 'composerData:\(cid)' LIMIT 1;"
                        var kvStmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, kvSql, -1, &kvStmt, nil) == SQLITE_OK {
                            defer { sqlite3_finalize(kvStmt) }
                            if sqlite3_step(kvStmt) == SQLITE_ROW {
                                let kvVal = columnString(kvStmt, 0)
                                if let kvData = kvVal.data(using: .utf8),
                                   let kvJson = try? JSONSerialization.jsonObject(with: kvData) as? [String: Any] {
                                    let cStatus = kvJson["status"] as? String ?? ""
                                    let bubbles = kvJson["generatingBubbleIds"] as? [Any] ?? []
                                    if cStatus == "generating" || !bubbles.isEmpty {
                                        isGeneratingInDb = true
                                    }
                                }
                            }
                        }

                        let displayTitle: String
                        if !nameFromHeader.isEmpty && nameFromHeader != "New Agent" {
                            displayTitle = nameFromHeader
                        } else if let t = latestTitles[cid]?.title, !t.isEmpty {
                            displayTitle = t
                        } else if let bestRecent = latestTitles.values.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                            displayTitle = bestRecent.title
                        } else {
                            displayTitle = "Cursor Agent 会话"
                        }

                        let updatedDate = Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0)
                        let ageSec = Date().timeIntervalSince(updatedDate)

                        let status: TaskStatus
                        let detail: String
                        let sig: String
                        if hasBlocking {
                            status = .waiting
                            detail = "等待确认执行操作 (Pending Approval)"
                            sig = "cursor-wait-\(cid)-\(updatedMs / 10000)"
                        } else if isGeneratingInDb && ageSec < 120 {
                            status = .running
                            detail = "Cursor Agent 正在生成代码/执行任务..."
                            sig = ""
                        } else {
                            status = .completed
                            detail = "Cursor Agent 任务已就绪"
                            sig = "cursor-done-\(cid)-\(updatedMs / 10000)"
                        }

                        items.append(AITaskItem(
                            id: "cursor-local-\(cid)",
                            appName: "Cursor",
                            bundleId: bundleId,
                            appPath: appPath,
                            category: .ide,
                            taskTitle: displayTitle,
                            workspace: workspaceName,
                            fullWorkspacePath: "",
                            statusDetail: detail,
                            modelName: "Cursor Agent",
                            status: status,
                            cpuPercent: cpu,
                            updatedAt: updatedDate,
                            isAppRunning: isRunning,
                            completionSignature: sig,
                            canTriggerAlert: true
                        ))
                    }
                }
            }

            let cloudSql = "SELECT value FROM ItemTable WHERE key LIKE 'cloudAgentRepository.agents%' LIMIT 1;"
            var cloudStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, cloudSql, -1, &cloudStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(cloudStmt) }
                if sqlite3_step(cloudStmt) == SQLITE_ROW {
                    let rawJson = columnString(cloudStmt, 0)
                    if let data = rawJson.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                       let latestAgent = arr.first {
                        let bcId = latestAgent["bcId"] as? String ?? "cloud-1"
                        let name = latestAgent["name"] as? String ?? "Background Agent"
                        let statusCode = latestAgent["status"] as? Int ?? 2
                        let pending = latestAgent["hasPendingInteraction"] as? Bool ?? false
                        let updatedMs = latestAgent["updatedAt"] as? Int64 ?? 0
                        let repoUrls = latestAgent["repoUrls"] as? [String] ?? []
                        let repoName = repoUrls.first.map { ($0 as NSString).lastPathComponent } ?? "Cloud Workspace"

                        let status: TaskStatus
                        let detail: String
                        let sig: String
                        if pending {
                            status = .waiting
                            detail = "云端 Agent 等待您的交互确认"
                            sig = "cursor-cloud-wait-\(bcId)-\(updatedMs)"
                        } else if statusCode == 1 {
                            status = .running
                            detail = "云端 Background Agent 正在运行..."
                            sig = ""
                        } else {
                            status = .completed
                            detail = "云端 Background Agent 已完成"
                            sig = "cursor-cloud-done-\(bcId)-\(updatedMs)"
                        }

                        items.append(AITaskItem(
                            id: "cursor-cloud-\(bcId)",
                            appName: "Cursor Cloud",
                            bundleId: bundleId,
                            appPath: appPath,
                            category: .ide,
                            taskTitle: name,
                            workspace: repoName,
                            fullWorkspacePath: "",
                            statusDetail: detail,
                            modelName: "Background Agent",
                            status: status,
                            cpuPercent: cpu,
                            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000.0),
                            isAppRunning: isRunning,
                            completionSignature: sig,
                            canTriggerAlert: true
                        ))
                    }
                }
            }
        }

        return items
    }

    // MARK: - 7. OpenCode Scanner

    private func scanOpenCode(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "ai.opencode.desktop"
        let appPath = "/Applications/OpenCode.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId }) || cpu > 0.1
        let dbPath = "\(homeDir)/.local/share/opencode/opencode.db"

        var items: [AITaskItem] = []
        guard let db = openReadOnlySQLite(path: dbPath) else { return items }
        defer { sqlite3_close(db) }

        var pendingSessions = Set<String>()
        var pendStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT DISTINCT session_id FROM session_pending;", -1, &pendStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(pendStmt) }
            while sqlite3_step(pendStmt) == SQLITE_ROW {
                pendingSessions.insert(columnString(pendStmt, 0))
            }
        }

        let sql = """
        SELECT id, title, directory, model, time_updated, IFNULL(time_idle, 0), IFNULL(idle_outcome, '')
        FROM session_v2
        WHERE time_archived IS NULL
        ORDER BY time_updated DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sid = columnString(stmt, 0)
                let title = columnString(stmt, 1)
                let directory = columnString(stmt, 2)
                let modelJson = columnString(stmt, 3)
                let timeUpdated = sqlite3_column_int64(stmt, 4)
                let timeIdle = sqlite3_column_int64(stmt, 5)
                let idleOutcome = columnString(stmt, 6)

                var modelName = "OpenCode"
                if let mData = modelJson.data(using: .utf8),
                   let mObj = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
                   let mid = mObj["id"] as? String {
                    modelName = mid
                }

                var lastMsgSeq: Int64 = 0
                var lastMsgType = "idle"
                var lastMsgCreated: Int64 = timeUpdated
                let msgSql = "SELECT seq, type, time_created FROM session_message WHERE session_id = '\(sid)' ORDER BY seq DESC LIMIT 1;"
                var msgStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, msgSql, -1, &msgStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(msgStmt) }
                    if sqlite3_step(msgStmt) == SQLITE_ROW {
                        lastMsgSeq = sqlite3_column_int64(msgStmt, 0)
                        lastMsgType = columnString(msgStmt, 1)
                        lastMsgCreated = sqlite3_column_int64(msgStmt, 2)
                    }
                }

                let updatedDate = Date(timeIntervalSince1970: TimeInterval(max(timeUpdated, lastMsgCreated)) / 1000.0)
                let ageSec = Date().timeIntervalSince(updatedDate)
                let isSessionBusy = pendingSessions.contains(sid) || (lastMsgType != "idle" && ageSec < 1800 && isRunning)

                let status: TaskStatus
                let detail: String
                let sig: String
                if isSessionBusy {
                    status = .running
                    detail = "OpenCode Agent 正在执行任务 (\(lastMsgType))..."
                    sig = ""
                } else if idleOutcome == "failed" && ageSec < 3600 {
                    status = .error
                    detail = "任务中断或执行失败 (failed)"
                    sig = "opencode-err-\(sid)-\(lastMsgSeq)"
                } else {
                    status = .completed
                    detail = "OpenCode 会话任务已完成"
                    sig = "opencode-done-\(sid)-\(lastMsgSeq > 0 ? lastMsgSeq : timeIdle)"
                }

                let wsName = directory.isEmpty ? "默认目录" : (directory as NSString).lastPathComponent
                items.append(AITaskItem(
                    id: "opencode-\(sid)",
                    appName: "OpenCode",
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .desktop,
                    taskTitle: title.isEmpty ? "OpenCode 会话" : title,
                    workspace: wsName,
                    fullWorkspacePath: directory,
                    statusDetail: detail,
                    modelName: modelName,
                    status: status,
                    cpuPercent: cpu,
                    updatedAt: updatedDate,
                    isAppRunning: isRunning,
                    completionSignature: sig,
                    canTriggerAlert: true
                ))
            }
        }

        return items
    }

    // MARK: - 8. Claude Desktop & Claude Code Scanner

    private func scanClaude(runningApps: [RunningAppInfo], cpu: Double) -> [AITaskItem] {
        let bundleId = "com.anthropic.claudefordesktop"
        let appPath = "/Applications/Claude.app"
        let isRunning = runningApps.contains(where: { $0.bundleId == bundleId })

        var items: [AITaskItem] = []
        let historyPath = "\(homeDir)/.claude/history.jsonl"

        if let tail = readFileTail(path: historyPath, maxBytes: 16 * 1024),
           let lastLine = tail.split(separator: "\n").last,
           let data = lastLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let display = (json["display"] as? String ?? "Claude Code 任务")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let project = json["project"] as? String ?? ""
            let tsMs = json["timestamp"] as? Int64 ?? 0
            let date = tsMs > 0 ? Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0) : Date()
            let age = Date().timeIntervalSince(date)

            if isRunning || age < 86400 * 3 {
                items.append(AITaskItem(
                    id: "claude-code-main",
                    appName: "Claude",
                    bundleId: bundleId,
                    appPath: appPath,
                    category: .cli,
                    taskTitle: String(display.prefix(60)),
                    workspace: project.isEmpty ? "Claude 会话" : (project as NSString).lastPathComponent,
                    fullWorkspacePath: project,
                    statusDetail: isRunning ? "Claude 在线就绪" : "历史任务已结束",
                    modelName: "Claude",
                    status: .completed,
                    cpuPercent: cpu,
                    updatedAt: date,
                    isAppRunning: isRunning,
                    completionSignature: "claude-\(tsMs)",
                    canTriggerAlert: false
                ))
            }
        } else if isRunning {
            items.append(AITaskItem(
                id: "claude-desktop",
                appName: "Claude",
                bundleId: bundleId,
                appPath: appPath,
                category: .desktop,
                taskTitle: "Claude 桌面端对话",
                workspace: "全局会话",
                fullWorkspacePath: "",
                statusDetail: "空闲就绪",
                modelName: "Claude",
                status: .idle,
                cpuPercent: cpu,
                updatedAt: Date(),
                isAppRunning: true,
                completionSignature: "claude-idle",
                canTriggerAlert: false
            ))
        }

        return items
    }

    // MARK: - 9. Other Running AI IDEs

    private func scanOtherIDEs(runningApps: [RunningAppInfo], procMetrics: ProcessMetrics) -> [AITaskItem] {
        let candidates: [(name: String, bundleId: String, path: String, cpuKey: String, model: String)] = [
            ("Kimi 桌面端", "com.moonshot.kimichat", "/Applications/Kimi.app", "kimi", "Kimi Chat"),
            ("Visual Studio Code", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app", "vscode", "Copilot / IDE"),
            ("Trae", "com.trae.app", "/Applications/Trae.app", "trae", "Trae Builder"),
            ("Trae CN", "cn.trae.app", "/Applications/Trae CN.app", "trae", "Trae Builder"),
            ("TRAE SOLO", "cn.trae.solo.app", "/Applications/TRAE SOLO CN.app", "trae", "SOLO Agent"),
            ("CodeBuddy CN", "com.tencent.codebuddycn", "/Applications/CodeBuddy CN.app", "codebuddy", "CodeBuddy AI")
        ]

        var results: [AITaskItem] = []
        for cand in candidates {
            guard runningApps.contains(where: { $0.bundleId == cand.bundleId }) else { continue }
            let cpu = procMetrics.cpuByKeyword[cand.cpuKey] ?? 0.0
            let taskId = "ide-\(cand.bundleId)"

            results.append(AITaskItem(
                id: taskId,
                appName: cand.name,
                bundleId: cand.bundleId,
                appPath: cand.path,
                category: .ide,
                taskTitle: "\(cand.name) 在线运行中",
                workspace: "活动窗口",
                fullWorkspacePath: "",
                statusDetail: "点击卡片可直接闪现切换到 \(cand.name) 窗口",
                modelName: cand.model,
                status: .idle,
                cpuPercent: cpu,
                updatedAt: Date(),
                isAppRunning: true,
                completionSignature: "ide-online",
                canTriggerAlert: false
            ))
        }
        return results
    }

    // MARK: - 10. Terminal CLI Agents

    private func scanTerminalCLITasks(cliList: [(pid: Int, tty: String, cpu: Double, cmd: String)]) -> [AITaskItem] {
        var results: [AITaskItem] = []
        for cli in cliList {
            results.append(AITaskItem(
                id: "cli-\(cli.tty)-\(cli.cmd)",
                appName: "终端 CLI (\(cli.cmd))",
                bundleId: "com.apple.Terminal",
                appPath: "/System/Applications/Utilities/Terminal.app",
                category: .cli,
                taskTitle: "终端运行中: \(cli.cmd) (PID \(cli.pid))",
                workspace: cli.tty,
                fullWorkspacePath: "",
                statusDetail: cli.cpu > 5.0 ? "CLI 活跃执行中..." : "终端等待输入就绪",
                modelName: cli.cmd.uppercased(),
                status: cli.cpu > 5.0 ? .running : .idle,
                cpuPercent: cli.cpu,
                updatedAt: Date(),
                isAppRunning: true,
                completionSignature: "cli-\(cli.pid)",
                canTriggerAlert: false
            ))
        }
        return results
    }

    // MARK: - Helpers

    private func openReadOnlySQLite(path: String) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 500)
            return db
        }
        if let db = db {
            sqlite3_close(db)
        }
        return nil
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private func readFileTail(path: String, maxBytes: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let startOffset = end > maxBytes ? (end - maxBytes) : 0
            try handle.seek(toOffset: startOffset)
            let data = handle.readDataToEndOfFile()
            // 截断点常落在中文/emoji 等多字节 UTF-8 字符中间，严格解码会让整段返回 nil；
            // 宽松解码只会损坏残缺的首行，而首行本就会被调用方的逐行 JSON 解析跳过
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func extractBetween(_ text: String, start: String, end: String) -> String? {
        guard let startRange = text.range(of: start) else { return nil }
        let searchRange = startRange.upperBound..<text.endIndex
        guard let endRange = text.range(of: end, range: searchRange) else { return nil }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }

    // MARK: - Stress Test Verification Hooks

    func stressTestTailRead(path: String, maxBytes: UInt64) -> Bool {
        guard let text = readFileTail(path: path, maxBytes: maxBytes) else { return false }
        return text.contains("turn.step.started")
    }

    func stressTestNotificationAntiSpam() -> Bool {
        let testEngine = TelemetryEngine(autoStart: false)
        testEngine.soundEnabled = false
        testEngine.voiceEnabled = false
        testEngine.systemBannerEnabled = false

        let baseTask = AITaskItem(
            id: "stress-spam-1",
            appName: "DeepSeek",
            bundleId: "com.deepseek.dsh",
            appPath: "/Applications/DeepSeek Harness.app",
            category: .desktop,
            taskTitle: "压测防通知轰炸任务",
            workspace: "deepseek",
            fullWorkspacePath: "",
            statusDetail: "已完成",
            modelName: "deepseek-reasoner",
            status: .completed,
            cpuPercent: 0,
            updatedAt: Date(),
            isAppRunning: true,
            completionSignature: "sig-fixed-100",
            canTriggerAlert: true
        )

        // 1. 首次扫描 + 200 次重复相同签名或短时 (<6s) CPU 抖动：应当产生 0 条通知
        for i in 0..<200 {
            var item = baseTask
            if i % 3 == 1 {
                item.status = .running
                item.completionSignature = ""
            } else {
                item.status = .completed
                item.completionSignature = "sig-fixed-100"
            }
            testEngine.processScannedTasks([item], frontmostBundleId: "com.other.app")
        }
        guard testEngine.recentAlerts.isEmpty else { return false }

        // 2. 真实长任务（运行 > 7 秒后变为新签名 completed）：应当精确产生 1 条通知
        var runningItem = baseTask
        runningItem.status = .running
        runningItem.startedAt = Date().addingTimeInterval(-8.5)
        runningItem.completionSignature = ""
        testEngine.runningStartTimes[runningItem.id] = Date().addingTimeInterval(-8.5)
        testEngine.previousStatuses[runningItem.id] = .running

        var doneItem = baseTask
        doneItem.status = .completed
        doneItem.completionSignature = "sig-new-201"
        testEngine.processScannedTasks([doneItem], frontmostBundleId: "com.other.app")
        guard testEngine.recentAlerts.count == 1 else { return false }

        // 3. 30 秒冷却期内再次触发：应当被冷却拦截，仍保持 1 条通知
        testEngine.runningStartTimes[runningItem.id] = Date().addingTimeInterval(-9.0)
        testEngine.previousStatuses[runningItem.id] = .running
        var doneItem2 = baseTask
        doneItem2.status = .completed
        doneItem2.completionSignature = "sig-new-202"
        testEngine.processScannedTasks([doneItem2], frontmostBundleId: "com.other.app")
        return testEngine.recentAlerts.count == 1
    }
}
