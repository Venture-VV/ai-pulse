import Cocoa
import SwiftUI

enum TaskStatus: String, Codable, CaseIterable {
    case running = "running"       // 正在执行/思考中
    case waiting = "waiting"       // 等待用户确认/输入
    case completed = "completed"   // 任务已完成
    case error = "error"           // 任务异常/中断
    case idle = "idle"             // 软件在线空闲

    var label: String {
        switch self {
        case .running: return "狂飙中"
        case .waiting: return "等你拍板"
        case .completed: return "已搞定"
        case .error: return "有状况"
        case .idle: return "待命中"
        }
    }

    var sortPriority: Int {
        switch self {
        case .waiting: return 0
        case .running: return 1
        case .completed: return 2
        case .error: return 3
        case .idle: return 4
        }
    }

    var badgeColor: Color {
        switch self {
        case .running: return Color(red: 0.18, green: 0.72, blue: 1.0)
        case .waiting: return Color(red: 1.0, green: 0.64, blue: 0.12)
        case .completed: return Color(red: 0.16, green: 0.90, blue: 0.62)
        case .error: return Color(red: 1.0, green: 0.34, blue: 0.44)
        case .idle: return Color(red: 0.58, green: 0.63, blue: 0.75)
        }
    }
}

enum ToolCategory: String, Codable {
    case ide = "AI IDE"
    case cli = "CLI 终端"
    case desktop = "AI 桌面"
    case plugin = "扩展插件"
}

enum TaskFilterMode: String, CaseIterable {
    case all = "全部"
    case activeOnly = "活跃中"
    case onlineOnly = "在线软件"
}

struct AITaskItem: Identifiable, Equatable {
    let id: String                  // Unique task/session or app identifier
    let appName: String             // e.g. "Antigravity", "Cursor", "Kimi Code", "WorkBuddy", "Manus Studio"
    let bundleId: String            // e.g. "com.google.antigravity"
    let appPath: String             // e.g. "/Applications/Antigravity.app"
    let category: ToolCategory
    var taskTitle: String           // Current prompt / session title
    var workspace: String           // Project folder name or path
    var fullWorkspacePath: String   // Full path on disk if available
    var statusDetail: String        // e.g. "Step 41 · 正在调用: 内置浏览器自动化"
    var modelName: String           // e.g. "Gemini 4", "gpt-6-astra", "Kimi k2.5"
    var status: TaskStatus
    var cpuPercent: Double
    var updatedAt: Date
    var startedAt: Date? = nil
    var isAppRunning: Bool
    var completionSignature: String = ""
    var canTriggerAlert: Bool = true
    var justCompleted: Bool = false

    /// 每个 AI 软件专属的潮流霓虹主题色
    var brandColor: Color {
        let lower = appName.lowercased()
        if lower.contains("deepseek") {
            return Color(red: 0.22, green: 0.54, blue: 1.0)  // 鲸海宝蓝 DeepSeek Blue
        } else if lower.contains("grok") {
            return Color(red: 1.0, green: 0.36, blue: 0.28)  // xAI 烈焰橘红 Grok Crimson
        } else if lower.contains("kimi") {
            return Color(red: 0.05, green: 0.82, blue: 0.96) // 电光青 Cyan
        } else if lower.contains("manus") {
            return Color(red: 0.92, green: 0.34, blue: 0.78) // 赛博洋红 Magenta
        } else if lower.contains("workbuddy") || lower.contains("codebuddy") {
            return Color(red: 1.0, green: 0.52, blue: 0.22)  // 活力珊瑚橙 Coral
        } else if lower.contains("antigravity") {
            return Color(red: 0.58, green: 0.40, blue: 1.0)  // 星际电紫 Violet
        } else if lower.contains("codex") || lower.contains("chatgpt") {
            return Color(red: 0.12, green: 0.86, blue: 0.62) // 薄荷翠绿 Emerald
        } else if lower.contains("cursor") {
            return Color(red: 0.26, green: 0.58, blue: 1.0)  // 极客深蓝 Electric Blue
        } else if lower.contains("opencode") {
            return Color(red: 0.56, green: 0.90, blue: 0.22) // 荧光青柠 Lime
        } else if lower.contains("claude") {
            return Color(red: 0.94, green: 0.56, blue: 0.30) // 暖金琥珀 Terracotta
        } else {
            return Color(red: 0.45, green: 0.68, blue: 1.0)
        }
    }

    var relativeTimeString: String {
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds)s 前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m 前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h 前" }
        return "\(hours / 24)d 前"
    }

    func elapsedDurationString(now: Date) -> String {
        let ref = startedAt ?? updatedAt
        let total = max(1, Int(now.timeIntervalSince(ref)))
        let mins = total / 60
        let secs = total % 60
        if mins >= 60 {
            let hrs = mins / 60
            let remMins = mins % 60
            return String(format: "%d:%02d:%02d", hrs, remMins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    static func == (lhs: AITaskItem, rhs: AITaskItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.taskTitle == rhs.taskTitle &&
        lhs.statusDetail == rhs.statusDetail &&
        lhs.justCompleted == rhs.justCompleted &&
        lhs.completionSignature == rhs.completionSignature &&
        lhs.isAppRunning == rhs.isAppRunning &&
        Int(lhs.cpuPercent) == Int(rhs.cpuPercent) &&
        Int(lhs.updatedAt.timeIntervalSince1970) == Int(rhs.updatedAt.timeIntervalSince1970)
    }
}

struct CompletionAlert: Identifiable, Equatable {
    let id = UUID()
    let taskId: String
    let appName: String
    let bundleId: String
    let appPath: String
    let workspace: String
    let taskTitle: String
    let status: TaskStatus
    let timestamp: Date
}
