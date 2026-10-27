import Cocoa
import Combine
import SwiftUI

final class FloatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingHUDPanel!
    private let engine = TelemetryEngine()
    private var cancellables = Set<AnyCancellable>()
    private var isMiniMode: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupFloatingPanel()
        setupStatusBarItem()
        bindEngineUpdates()
    }

    private func setupFloatingPanel() {
        let initialSize = NSSize(width: 416, height: 610)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.maxX - initialSize.width - 18
        let originY = screenFrame.maxY - initialSize.height - 12

        panel = FloatingHUDPanel(contentRect: NSRect(origin: NSPoint(x: originX, y: originY), size: initialSize))
        updatePanelContent()
        panel.orderFrontRegardless()
    }

    private func updatePanelContent() {
        let miniBinding = Binding<Bool>(
            get: { [weak self] in self?.isMiniMode ?? false },
            set: { [weak self] newVal in
                self?.setMiniMode(newVal)
            }
        )

        let rootView = MainHUDView(
            engine: engine,
            isMiniMode: miniBinding,
            onToggleMiniMode: { [weak self] in
                guard let self = self else { return }
                self.setMiniMode(!self.isMiniMode)
            },
            onClosePanel: { [weak self] in
                self?.panel.orderOut(nil)
            }
        )

        panel.contentView = NSHostingView(rootView: rootView)
    }

    private func setMiniMode(_ mini: Bool) {
        guard isMiniMode != mini else { return }
        isMiniMode = mini

        let oldFrame = panel.frame
        let newSize = mini ? NSSize(width: 316, height: 50) : NSSize(width: 416, height: 610)
        // 保持右上角锚点不变，缩放更加自然
        let newOriginX = oldFrame.maxX - newSize.width
        let newOriginY = oldFrame.maxY - newSize.height
        let newFrame = NSRect(origin: NSPoint(x: newOriginX, y: max(20, newOriginY)), size: newSize)

        updatePanelContent()
        panel.setFrame(newFrame, display: true, animate: true)
    }

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "✦ AI 监控"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePanel()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: panel.isVisible ? "隐藏桌面悬浮窗" : "显示桌面悬浮窗",
            action: #selector(menuTogglePanel),
            keyEquivalent: "p"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let miniItem = NSMenuItem(
            title: isMiniMode ? "展开完整监控面板" : "切换为迷你胶囊模式",
            action: #selector(menuToggleMini),
            keyEquivalent: "m"
        )
        miniItem.target = self
        menu.addItem(miniItem)

        let testAlertItem = NSMenuItem(
            title: "⚡ 测试完成提醒与跳转",
            action: #selector(menuSimulateAlert),
            keyEquivalent: "t"
        )
        testAlertItem.target = self
        menu.addItem(testAlertItem)

        let dndItem = NSMenuItem(
            title: engine.doNotDisturbEnabled ? "🌙 关闭全局免打扰" : "🌙 开启全局免打扰",
            action: #selector(menuToggleDND),
            keyEquivalent: "d"
        )
        dndItem.target = self
        menu.addItem(dndItem)

        let pluginDirItem = NSMenuItem(
            title: "🧩 打开插件与状态接入目录 (~/.ai-pulse)",
            action: #selector(menuOpenPluginFolder),
            keyEquivalent: "o"
        )
        pluginDirItem.target = self
        menu.addItem(pluginDirItem)

        menu.addItem(NSMenuItem.separator())

        // 快捷跳转子列表
        for task in engine.tasks.prefix(10) {
            let statusIcon: String
            switch task.status {
            case .running: statusIcon = "⚡"
            case .waiting: statusIcon = "🟠"
            case .completed: statusIcon = "✅"
            case .error: statusIcon = "❌"
            case .idle: statusIcon = "⚪"
            }
            let item = NSMenuItem(
                title: "\(statusIcon) [\(task.appName)] \(task.taskTitle.prefix(26))",
                action: #selector(menuJumpToTask(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = task
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "退出 AI Pulse 监控",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuTogglePanel() {
        togglePanel()
    }

    @objc private func menuToggleMini() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        setMiniMode(!isMiniMode)
    }

    @objc private func menuSimulateAlert() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        engine.simulateCompletionAlert()
    }

    @objc private func menuToggleDND() {
        engine.doNotDisturbEnabled.toggle()
    }

    @objc private func menuOpenPluginFolder() {
        ProviderRegistry.shared.openPluginFolderInFinder()
    }

    @objc private func menuJumpToTask(_ sender: NSMenuItem) {
        guard let task = sender.representedObject as? AITaskItem else { return }
        WindowActivator.shared.focusApp(
            bundleId: task.bundleId,
            appPath: task.appPath,
            workspaceHint: task.workspace
        )
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    private func bindEngineUpdates() {
        engine.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in
                guard let self = self, let button = self.statusItem.button else { return }
                let running = tasks.filter { $0.status == .running }.count
                let waiting = tasks.filter { $0.status == .waiting }.count
                let justDone = tasks.filter { $0.justCompleted }.count

                if waiting > 0 {
                    button.title = "🟠 \(waiting) 待确认 · AI"
                } else if justDone > 0 {
                    button.title = "🎉 \(justDone) 刚完成 · AI"
                } else if running > 0 {
                    button.title = "⚡ \(running) 运行中 · AI"
                } else {
                    let online = tasks.filter { $0.isAppRunning }.count
                    button.title = "✦ AI 监控 (\(online))"
                }
            }
            .store(in: &cancellables)

        engine.$activeAlert
            .receive(on: RunLoop.main)
            .sink { [weak self] alert in
                guard let self = self, alert != nil else { return }
                // 当有新完成通知时，如果悬浮窗被隐藏，自动浮现提醒用户
                if !self.panel.isVisible {
                    self.panel.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)
    }
}

@main
struct AIPulseMain {
    static func main() {
        if CommandLine.arguments.contains("--stress-test") {
            let ok = StressTestRunner.runAll()
            exit(ok ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test") {
            let engine = TelemetryEngine(autoStart: false)
            let results = engine.performSynchronousSelfTest()
            print("=== AI Pulse Self-Test Diagnostics (\(results.count) tools detected) ===")
            for (idx, item) in results.enumerated() {
                print("[\(idx + 1)] \(item.appName) | Status: \(item.status.label) | Running: \(item.isAppRunning) | Model: \(item.modelName)")
                print("    Workspace: \(item.workspace)")
                print("    Title:     \(item.taskTitle)")
                print("    Detail:    \(item.statusDetail)")
                print("    Sig:       \(item.completionSignature)")
            }
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
