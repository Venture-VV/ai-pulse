import AVFoundation
import Cocoa
import UserNotifications

final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for appPath: String, bundleId: String) -> NSImage {
        if let cached = cache[appPath] {
            return cached
        }
        if FileManager.default.fileExists(atPath: appPath) {
            let img = NSWorkspace.shared.icon(forFile: appPath)
            img.size = NSSize(width: 32, height: 32)
            cache[appPath] = img
            return img
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let img = NSWorkspace.shared.icon(forFile: url.path)
            img.size = NSSize(width: 32, height: 32)
            cache[appPath] = img
            return img
        }
        let fallback = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: nil) ?? NSImage()
        return fallback
    }
}

final class WindowActivator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WindowActivator()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var notificationMap: [String: (bundleId: String, appPath: String, workspace: String)] = [:]

    override init() {
        super.init()
        setupNotifications()
    }

    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 启动时自动清理之前残留的系统通知弹窗
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    func requestNotificationPermissionIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 聚焦并跳转到指定 AI 工具窗口（支持多桌面 Space 自动切换与指定项目窗口置顶）
    func focusApp(bundleId: String, appPath: String, workspaceHint: String = "") {
        DispatchQueue.main.async {
            // 1. 尝试直接通过 NSRunningApplication 激活
            let runningApps = NSWorkspace.shared.runningApplications
            if let targetApp = runningApps.first(where: { $0.bundleIdentifier == bundleId }) {
                targetApp.unhide()
                targetApp.activate(options: [.activateAllWindows])
            }

            // 2. 通过 NSWorkspace 打开应用路径（可触发 macOS 自动切换到对应全屏/桌面 Space 并取消最小化）
            let appURL: URL?
            if FileManager.default.fileExists(atPath: appPath) {
                appURL = URL(fileURLWithPath: appPath)
            } else {
                appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            }

            if let url = appURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            }

            // 3. 若提供了项目名/工作区提示，异步尝试将该应用包含对应标题的窗口置顶 (AXRaise)
            let cleanHint = workspaceHint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanHint.isEmpty && cleanHint != "默认工作区" && cleanHint != "全局会话" {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) {
                    self.raiseMatchingWindow(bundleId: bundleId, windowKeyword: cleanHint)
                }
            }
        }
    }

    private func raiseMatchingWindow(bundleId: String, windowKeyword: String) {
        // 必须先转义反斜杠再转义双引号：否则输入里的 `\"` 会提前闭合 AppleScript 字符串，拼出可执行的脚本
        func appleScriptEscaped(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let escapedBundleId = appleScriptEscaped(bundleId)
        let escapedKeyword = appleScriptEscaped(windowKeyword)
        let script = """
        tell application "System Events"
            set procList to every process whose bundle identifier is "\(escapedBundleId)"
            if (count of procList) > 0 then
                set targetProc to item 1 of procList
                set frontmost of targetProc to true
                repeat with w in (every window of targetProc)
                    try
                        if (name of w) contains "\(escapedKeyword)" then
                            perform action "AXRaise" of w
                            exit repeat
                        end if
                    end try
                end repeat
            end if
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    /// 在 Finder 中打开项目工作区目录
    func openWorkspaceInFinder(path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// 发送完成/待确认提醒（支持面板内静默提醒、音效、语音、可选系统横幅，且同一软件固定替换 ID 绝不堆叠轰炸）
    func triggerAlert(
        alert: CompletionAlert,
        soundEnabled: Bool,
        voiceEnabled: Bool,
        systemBannerEnabled: Bool
    ) {
        if soundEnabled {
            let soundName = (alert.status == .waiting) ? "Funk" : "Glass"
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.play()
            }
        }

        if voiceEnabled {
            let actionText = (alert.status == .waiting) ? "等待您的确认" : "任务已完成"
            let speechText = "\(alert.appName)，\(actionText)"
            if !speechSynthesizer.isSpeaking {
                let utterance = AVSpeechUtterance(string: speechText)
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
                utterance.rate = 0.52
                speechSynthesizer.speak(utterance)
            }
        }

        // 仅在用户开启“系统原生弹窗”时才推送到 macOS 通知中心，并使用固定 app 标识符覆盖旧通知，绝不堆叠轰炸
        if systemBannerEnabled && Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            let statusEmoji = (alert.status == .waiting) ? "🟠 待确认" : "✅ 任务已完成"
            content.title = "\(statusEmoji) · \(alert.appName)"
            content.subtitle = alert.workspace.isEmpty ? "" : "项目: \(alert.workspace)"
            content.body = "\(alert.taskTitle)\n👉 点击立即跳转到 \(alert.appName)"
            content.sound = nil // 声音已由上面统一控制，避免双重响铃

            // 使用软件 bundleId 作为固定通知 ID，同一软件的新通知自动替换旧通知，不会产生满屏通知列表
            let reqId = "aipulse-\(alert.bundleId)"
            notificationMap[reqId] = (alert.bundleId, alert.appPath, alert.workspace)

            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [reqId])
            let request = UNNotificationRequest(identifier: reqId, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let reqId = response.notification.request.identifier
        if let info = notificationMap[reqId] {
            focusApp(bundleId: info.bundleId, appPath: info.appPath, workspaceHint: info.workspace)
        }
        completionHandler()
    }
}
