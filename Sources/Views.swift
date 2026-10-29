import Cocoa
import Combine
import SwiftUI

// MARK: - Native macOS Frosted Glass (NSVisualEffectView Wrapper)

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

enum TaskFilter: String, CaseIterable {
    case all = "全部"
    case active = "狂飙/拍板"
    case completed = "已搞定"
    case online = "在线引擎"
}

// MARK: - Animated Neural Waveform Indicator

struct NeuralWaveformView: View {
    let isActive: Bool
    let color: Color
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(
                        width: 2.6,
                        height: isActive
                            ? (animate ? CGFloat([13, 7, 15, 9][idx]) : CGFloat([6, 14, 8, 13][idx]))
                            : 5
                    )
                    .animation(
                        isActive
                            ? .easeInOut(duration: Double([0.42, 0.55, 0.38, 0.48][idx])).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.25),
                        value: animate
                    )
            }
        }
        .frame(width: 18, height: 16)
        .onAppear {
            if isActive {
                animate = true
            }
        }
        .onChange(of: isActive) { active in
            if active {
                animate = false
                DispatchQueue.main.async {
                    animate = true
                }
            } else {
                animate = false
            }
        }
    }
}

// MARK: - Main HUD View

struct MainHUDView: View {
    @ObservedObject var engine: TelemetryEngine
    var onToggleMiniMode: () -> Void
    var onClosePanel: () -> Void

    @State private var selectedFilter: TaskFilter = .all
    @State private var searchQuery: String = ""
    @State private var showSearchBar: Bool = false
    @State private var hoveredTaskId: String? = nil
    @State private var pulsePhase: Bool = false
    @State private var nowTick: Date = Date()

    private let tickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var runningCount: Int {
        engine.tasks.filter { $0.status == .running }.count
    }

    private var waitingCount: Int {
        engine.tasks.filter { $0.status == .waiting }.count
    }

    private var completedCount: Int {
        engine.tasks.filter { $0.status == .completed }.count
    }

    private var uniqueOnlineTasks: [AITaskItem] {
        var seen = Set<String>()
        var list: [AITaskItem] = []
        for t in engine.tasks where t.isAppRunning {
            let key = t.bundleId.isEmpty ? t.appName : t.bundleId
            if !seen.contains(key) {
                seen.insert(key)
                list.append(t)
            }
        }
        return list
    }

    private var onlineCount: Int {
        uniqueOnlineTasks.count
    }

    private var filteredTasks: [AITaskItem] {
        let base: [AITaskItem]
        switch selectedFilter {
        case .all:
            base = engine.tasks
        case .active:
            base = engine.tasks.filter { $0.status == .running || $0.status == .waiting }
        case .completed:
            base = engine.tasks.filter { $0.status == .completed }
        case .online:
            base = engine.tasks.filter { $0.isAppRunning }
        }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return base }
        return base.filter { item in
            item.appName.lowercased().contains(trimmed) ||
            item.taskTitle.lowercased().contains(trimmed) ||
            item.workspace.lowercased().contains(trimmed) ||
            item.modelName.lowercased().contains(trimmed) ||
            item.statusDetail.lowercased().contains(trimmed)
        }
    }

    private var ambientAuraColor: Color {
        if waitingCount > 0 {
            return Color(red: 1.0, green: 0.56, blue: 0.12)
        }
        if runningCount > 0 {
            return Color(red: 0.12, green: 0.72, blue: 1.0)
        }
        return Color(red: 0.16, green: 0.88, blue: 0.62)
    }

    var body: some View {
        Group {
            if engine.isMiniMode {
                miniCapsuleView
            } else {
                expandedDashboardView
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
        }
        .onReceive(tickTimer) { t in
            nowTick = t
        }
    }

    // MARK: - 1. 灵动岛迷你胶囊视图 (Dynamic Island Mini Pill)

    private var miniCapsuleView: some View {
        HStack(spacing: 10) {
            // 活跃软件叠放头像 (Avatar Stack)
            HStack(spacing: -7) {
                ForEach(Array(uniqueOnlineTasks.prefix(4).enumerated()), id: \.element.id) { idx, t in
                    Image(nsImage: AppIconCache.shared.icon(for: t.appPath, bundleId: t.bundleId))
                        .resizable()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.black.opacity(0.8), lineWidth: 1.5)
                        )
                        .zIndex(Double(10 - idx))
                }
            }

            NeuralWaveformView(isActive: runningCount > 0 || waitingCount > 0, color: ambientAuraColor)

            if let alert = engine.activeAlert {
                let alertLabel: String = {
                    switch alert.status {
                    case .waiting: return "🟠 \(alert.appName) 等你拍板"
                    case .error: return "❌ \(alert.appName) 有状况"
                    default: return "✨ \(alert.appName) 已搞定"
                    }
                }()
                let alertColor: Color = {
                    switch alert.status {
                    case .waiting: return .orange
                    case .error: return Color(red: 1.0, green: 0.40, blue: 0.40)
                    default: return Color(red: 0.25, green: 0.96, blue: 0.68)
                    }
                }()
                Button(action: {
                    WindowActivator.shared.focusApp(
                        bundleId: alert.bundleId,
                        appPath: alert.appPath,
                        workspaceHint: alert.workspace
                    )
                    engine.activeAlert = nil
                }) {
                    HStack(spacing: 6) {
                        Text(alertLabel)
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundColor(alertColor)
                            .lineLimit(1)
                        Text("闪现 ↗")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.16, green: 0.88, blue: 0.58), Color(red: 0.08, green: 0.68, blue: 0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(6)
                            .foregroundColor(.black)
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    if runningCount > 0 {
                        Text("⚡\(runningCount) 狂飙中")
                            .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                            .foregroundColor(Color(red: 0.35, green: 0.82, blue: 1.0))
                    }
                    if waitingCount > 0 {
                        Text("🟠\(waitingCount) 拍板")
                            .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                            .foregroundColor(.orange)
                    }
                    Text("✅\(completedCount)")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundColor(Color(red: 0.22, green: 0.90, blue: 0.62))
                }
            }

            Spacer(minLength: 2)

            Button(action: onToggleMiniMode) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("展开 AI Pulse 完整监控舱")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(width: 316, height: 50)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color(red: 0.05, green: 0.07, blue: 0.11).opacity(0.84)
                LinearGradient(
                    colors: [ambientAuraColor.opacity(0.22), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .clipShape(Capsule(style: .continuous))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            ambientAuraColor.opacity(engine.activeAlert != nil ? 0.9 : 0.55),
                            Color.white.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.3
                )
        )
    }

    // MARK: - 2. 展开完整赛博毛玻璃看板 (Expanded Cyber-Glass HUD)

    private var expandedDashboardView: some View {
        VStack(spacing: 0) {
            headerBar

            // 顶部实时完成/待确认提醒横幅
            if let alert = engine.activeAlert {
                completionBanner(alert)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            summaryBentoBar
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)

            filterBar
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            // 任务卡片滚动列表
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 9) {
                    if filteredTasks.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(filteredTasks) { item in
                            TaskCardView(
                                item: item,
                                nowTick: nowTick,
                                isHovered: hoveredTaskId == item.id,
                                onJump: {
                                    WindowActivator.shared.focusApp(
                                        bundleId: item.bundleId,
                                        appPath: item.appPath,
                                        workspaceHint: item.workspace
                                    )
                                },
                                onOpenFolder: {
                                    WindowActivator.shared.openWorkspaceInFinder(path: item.fullWorkspacePath)
                                }
                            )
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    hoveredTaskId = hovering ? item.id : nil
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            footerBar
        }
        .frame(width: 416, height: 610)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color(red: 0.05, green: 0.06, blue: 0.10).opacity(0.86)

                // 顶部动态极光渐变氛围层 (Aurora Glow)
                RadialGradient(
                    colors: [
                        ambientAuraColor.opacity(0.24),
                        Color(red: 0.45, green: 0.22, blue: 0.95).opacity(0.08),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 340
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.26),
                            ambientAuraColor.opacity(0.35),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            // 动态音频/神经脉冲律动条
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ambientAuraColor.opacity(0.16))
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(ambientAuraColor.opacity(0.45), lineWidth: 1)
                    )
                NeuralWaveformView(isActive: runningCount > 0 || waitingCount > 0, color: ambientAuraColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("AI PULSE")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(red: 0.78, green: 0.90, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("RADAR 2.0")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.48, green: 0.32, blue: 1.0), Color(red: 0.12, green: 0.72, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }

                // 在线 AI 叠放迷你图标栏
                HStack(spacing: 4) {
                    HStack(spacing: -5) {
                        ForEach(Array(uniqueOnlineTasks.prefix(6).enumerated()), id: \.element.id) { idx, t in
                            Image(nsImage: AppIconCache.shared.icon(for: t.appPath, bundleId: t.bundleId))
                                .resizable()
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                        .stroke(Color.black, lineWidth: 1)
                                )
                                .zIndex(Double(10 - idx))
                        }
                    }
                    Text("\(onlineCount) 款引擎在线 · 点卡片即刻闪现")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            Spacer()

            // 顶部潮流胶囊工具栏
            HStack(spacing: 3.5) {
                headerIconButton(
                    icon: engine.doNotDisturbEnabled ? "moon.zzz.fill" : "moon.fill",
                    isActive: engine.doNotDisturbEnabled,
                    activeColor: Color(red: 0.65, green: 0.50, blue: 1.0),
                    tooltip: engine.doNotDisturbEnabled ? "全局免打扰：已开启（暂停所有弹窗与声音提醒）" : "点击开启全局免打扰模式",
                    action: { engine.doNotDisturbEnabled.toggle() }
                )

                headerIconButton(
                    icon: engine.muteFrontmostApp ? "eye.slash.fill" : "eye.fill",
                    isActive: engine.muteFrontmostApp,
                    activeColor: Color(red: 0.20, green: 0.92, blue: 0.65),
                    tooltip: engine.muteFrontmostApp ? "前台免打扰：已开启（正在看的软件不弹窗）" : "前台免打扰：已关闭",
                    action: { engine.muteFrontmostApp.toggle() }
                )

                headerIconButton(
                    icon: engine.systemBannerEnabled ? "bubble.right.fill" : "bubble.right",
                    isActive: engine.systemBannerEnabled,
                    activeColor: Color.orange,
                    tooltip: engine.systemBannerEnabled ? "macOS 系统横幅：已开启" : "macOS 系统横幅：已关闭（仅面板内轻提醒，防轰炸）",
                    action: { engine.systemBannerEnabled.toggle() }
                )

                headerIconButton(
                    icon: engine.soundEnabled ? "bell.fill" : "bell.slash",
                    isActive: engine.soundEnabled,
                    activeColor: Color(red: 1.0, green: 0.82, blue: 0.22),
                    tooltip: engine.soundEnabled ? "提示音效：已开启" : "提示音效：已静音",
                    action: { engine.soundEnabled.toggle() }
                )

                headerIconButton(
                    icon: engine.voiceEnabled ? "waveform.circle.fill" : "waveform.circle",
                    isActive: engine.voiceEnabled,
                    activeColor: Color(red: 0.22, green: 0.86, blue: 1.0),
                    tooltip: engine.voiceEnabled ? "语音播报：已开启" : "开启中文语音播报提醒",
                    action: { engine.voiceEnabled.toggle() }
                )

                headerIconButton(
                    icon: "capsule.portrait.fill",
                    isActive: false,
                    activeColor: .white,
                    tooltip: "折叠为灵动岛迷你胶囊",
                    action: onToggleMiniMode
                )

                headerIconButton(
                    icon: "xmark",
                    isActive: false,
                    activeColor: .white,
                    tooltip: "收起至顶部状态栏",
                    action: onClosePanel
                )
            }
            .padding(3.5)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private func headerIconButton(
        icon: String,
        isActive: Bool,
        activeColor: Color,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isActive ? activeColor : .white.opacity(0.55))
                .frame(width: 24, height: 24)
                .background(isActive ? activeColor.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Completion Alert Banner

    private func completionBanner(_ alert: CompletionAlert) -> some View {
        let bannerTitle: String = {
            switch alert.status {
            case .waiting: return "🟠 等你拍板 · \(alert.appName)"
            case .error: return "❌ 任务异常 · \(alert.appName)"
            default: return "🎉 刚刚搞定 · \(alert.appName)"
            }
        }()
        let bannerAccent: Color = {
            switch alert.status {
            case .waiting: return .orange
            case .error: return Color(red: 1.0, green: 0.40, blue: 0.40)
            default: return Color(red: 0.28, green: 0.98, blue: 0.68)
            }
        }()
        let bannerBgColors: [Color] = {
            if alert.status == .error {
                return [
                    Color(red: 0.36, green: 0.08, blue: 0.12).opacity(0.92),
                    Color(red: 0.24, green: 0.06, blue: 0.10).opacity(0.92)
                ]
            }
            return [
                Color(red: 0.08, green: 0.32, blue: 0.24).opacity(0.92),
                Color(red: 0.06, green: 0.18, blue: 0.26).opacity(0.92)
            ]
        }()

        return HStack(spacing: 10) {
            Image(nsImage: AppIconCache.shared.icon(for: alert.appPath, bundleId: alert.bundleId))
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(bannerTitle)
                        .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                        .foregroundColor(bannerAccent)
                    if !alert.workspace.isEmpty {
                        Text("#\(alert.workspace)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
                Text(alert.taskTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: {
                WindowActivator.shared.focusApp(
                    bundleId: alert.bundleId,
                    appPath: alert.appPath,
                    workspaceHint: alert.workspace
                )
                withAnimation {
                    engine.activeAlert = nil
                }
            }) {
                Text("闪现窗口 ↗")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.90, blue: 0.58), Color(red: 0.08, green: 0.72, blue: 0.92)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: {
                withAnimation {
                    engine.activeAlert = nil
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: bannerBgColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(bannerAccent.opacity(0.65), lineWidth: 1.2)
                )
        )
    }

    // MARK: - Bento KPI Grid

    private var summaryBentoBar: some View {
        HStack(spacing: 8) {
            bentoKPI(
                title: "正在狂飙",
                count: runningCount,
                color: Color(red: 0.18, green: 0.75, blue: 1.0),
                icon: "bolt.fill"
            )
            bentoKPI(
                title: "等你拍板",
                count: waitingCount,
                color: Color(red: 1.0, green: 0.64, blue: 0.14),
                icon: "hand.raised.fill"
            )
            bentoKPI(
                title: "已搞定",
                count: completedCount,
                color: Color(red: 0.16, green: 0.90, blue: 0.62),
                icon: "checkmark.seal.fill"
            )
            bentoKPI(
                title: "在线引擎",
                count: onlineCount,
                color: Color(red: 0.72, green: 0.48, blue: 1.0),
                icon: "cpu.fill"
            )
        }
    }

    private func bentoKPI(title: String, count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 26, height: 26)
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            count > 0 ? color.opacity(0.14) : Color.white.opacity(0.05),
                            Color.white.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            count > 0 ? color.opacity(0.45) : Color.white.opacity(0.07),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Segmented Filter Dock & Search Bar

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(TaskFilter.allCases, id: \.self) { filter in
                    let isSelected = (selectedFilter == filter)
                    let badgeCount = countForFilter(filter)
                    Button(action: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                            selectedFilter = filter
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .heavy : .semibold, design: .rounded))
                            if badgeCount > 0 {
                                Text("\(badgeCount)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 0.5)
                                    .background(isSelected ? Color.black.opacity(0.28) : Color.white.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Group {
                                if isSelected {
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.22, green: 0.62, blue: 1.0),
                                            Color(red: 0.46, green: 0.34, blue: 1.0)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                } else {
                                    Color.white.opacity(0.05)
                                }
                            }
                            .clipShape(Capsule())
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? Color.white.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .white : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // 快捷搜索框开关
                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        showSearchBar.toggle()
                        if !showSearchBar {
                            searchQuery = ""
                        }
                    }
                }) {
                    Image(systemName: showSearchBar || !searchQuery.isEmpty ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(showSearchBar || !searchQuery.isEmpty ? Color(red: 0.28, green: 0.82, blue: 1.0) : .white.opacity(0.65))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("按项目名 / AI 软件 / 任务关键字过滤")
            }

            if showSearchBar {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.45))

                    TextField("搜索 DeepSeek / Grok / Kimi / 项目名 / 关键词...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white)

                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(red: 0.28, green: 0.76, blue: 1.0).opacity(0.45), lineWidth: 1)
                )
            }
        }
    }

    private func countForFilter(_ f: TaskFilter) -> Int {
        switch f {
        case .all: return engine.tasks.count
        case .active: return runningCount + waitingCount
        case .completed: return completedCount
        case .online: return onlineCount
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 54, height: 54)
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(red: 0.38, green: 0.76, blue: 1.0))
            }
            Text("当前频道下暂无 AI 任务")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
            Text("当后台 AI 引擎开始工作时，这里会自动点亮")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.doNotDisturbEnabled ? Color.purple : Color(red: 0.16, green: 0.90, blue: 0.62))
                    .frame(width: 6, height: 6)
                Text(engine.doNotDisturbEnabled ? "全局免打扰开启中" : "防轰炸守卫 · 同轮仅提醒 1 次")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.50))
            }

            Spacer()

            if engine.tasks.contains(where: { $0.justCompleted }) || engine.activeAlert != nil {
                Button(action: {
                    withAnimation(.spring()) {
                        engine.clearCompletedHighlights()
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("全部已读")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.16, green: 0.88, blue: 0.62).opacity(0.16))
                    .foregroundColor(Color(red: 0.25, green: 0.96, blue: 0.68))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("清除所有卡片上的“刚刚搞定”高亮与顶部横幅")
            }

            Button(action: {
                ProviderRegistry.shared.openPluginFolderInFinder()
            }) {
                HStack(spacing: 3.5) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("插件扩展")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4.5)
                .background(Color(red: 0.25, green: 0.58, blue: 1.0).opacity(0.16))
                .foregroundColor(Color(red: 0.48, green: 0.80, blue: 1.0))
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(Color(red: 0.35, green: 0.72, blue: 1.0).opacity(0.32), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开 ~/.ai-pulse 插件与实时状态接入目录")

            Button(action: {
                withAnimation(.spring()) {
                    engine.simulateCompletionAlert()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                    Text("试玩提醒")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4.5)
                .background(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .foregroundColor(.white.opacity(0.92))
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("模拟触发一次任务搞定弹窗、音效与一键闪现跳转")

            Button(action: {
                engine.scanNow()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("立即同步最新状态")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.22))
    }
}

// MARK: - Redesigned Youthful Neo-Glass Task Card

struct TaskCardView: View {
    let item: AITaskItem
    let nowTick: Date
    let isHovered: Bool
    let onJump: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        Button(action: onJump) {
            HStack(spacing: 0) {
                // 左侧霓虹品牌/状态光条 (Neon Accent Bar)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                item.status == .running ? Color(red: 0.18, green: 0.82, blue: 1.0) : item.brandColor,
                                item.status.badgeColor.opacity(0.65)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3.5)
                    .padding(.vertical, 8)
                    .padding(.leading, 6)

                VStack(alignment: .leading, spacing: 7) {
                    // Top Row: App Icon + Brand Name + Model Pill + Status Badge
                    HStack(spacing: 9) {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: AppIconCache.shared.icon(for: item.appPath, bundleId: item.bundleId))
                                .resizable()
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .shadow(color: item.brandColor.opacity(isHovered ? 0.45 : 0.2), radius: 5, x: 0, y: 2)

                            // 在线状态绿点
                            Circle()
                                .fill(item.isAppRunning ? Color(red: 0.18, green: 0.95, blue: 0.58) : Color.gray.opacity(0.5))
                                .frame(width: 8.5, height: 8.5)
                                .overlay(Circle().stroke(Color(red: 0.06, green: 0.08, blue: 0.12), lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }

                        VStack(alignment: .leading, spacing: 2.5) {
                            HStack(spacing: 6) {
                                Text(item.appName)
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)

                                // 专属品牌色模型胶囊
                                Text(item.modelName)
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(item.brandColor.opacity(0.16))
                                    .foregroundColor(item.brandColor)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().strokeBorder(item.brandColor.opacity(0.32), lineWidth: 0.8)
                                    )
                                    .lineLimit(1)
                            }

                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 8.5))
                                    .foregroundColor(item.brandColor.opacity(0.8))
                                Text(item.workspace)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.62))
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        statusBadge
                    }

                    // Middle Row: Prompt / Conversation Task Title
                    Text(item.taskTitle)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Bottom Row: Step Detail + Live Timer / Relative Time + Folder + Jump Pill
                    HStack(spacing: 6) {
                        Text(item.statusDetail)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(
                                item.status == .running
                                    ? Color(red: 0.42, green: 0.84, blue: 1.0)
                                    : .white.opacity(0.54)
                            )
                            .lineLimit(1)

                        Spacer()

                        // 实时秒表计时器 (Running) 或 相对时间 (Completed/Idle)
                        if item.status == .running {
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9, weight: .bold))
                                Text(item.elapsedDurationString(now: nowTick))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(Color(red: 0.35, green: 0.84, blue: 1.0))
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.16))
                            .clipShape(Capsule())
                        } else {
                            Text(item.relativeTimeString)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.40))
                        }

                        if !item.fullWorkspacePath.isEmpty {
                            Button(action: onOpenFolder) {
                                Image(systemName: "folder.badge.gearshape")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.7))
                                    .frame(width: 22, height: 22)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("在 Finder 中打开工作目录: \(item.fullWorkspacePath)")
                        }

                        HStack(spacing: 2.5) {
                            Text("闪现")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .black))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Group {
                                if isHovered {
                                    LinearGradient(
                                        colors: [item.brandColor, Color(red: 0.25, green: 0.65, blue: 1.0)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                } else {
                                    Color.white.opacity(0.10)
                                }
                            }
                        )
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                item.justCompleted
                                    ? (item.status == .error
                                        ? Color(red: 0.42, green: 0.12, blue: 0.15).opacity(0.55)
                                        : Color(red: 0.12, green: 0.38, blue: 0.26).opacity(0.55))
                                    : (isHovered ? item.brandColor.opacity(0.15) : Color.white.opacity(0.055)),
                                Color.white.opacity(isHovered ? 0.06 : 0.025)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(cardBorderGradient, lineWidth: isHovered || item.status == .running || item.justCompleted ? 1.3 : 1.0)
                    )
            )
            .scaleEffect(isHovered ? 1.008 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var cardBorderGradient: LinearGradient {
        if item.justCompleted {
            if item.status == .error {
                return LinearGradient(
                    colors: [Color.red.opacity(0.9), Color.orange.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.95, blue: 0.65), Color.green.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        if item.status == .running {
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.78, blue: 1.0).opacity(0.85), item.brandColor.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        if isHovered {
            return LinearGradient(
                colors: [item.brandColor.opacity(0.75), Color.white.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.11), Color.white.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var statusBadge: some View {
        let badgeText: String = {
            guard item.justCompleted else { return item.status.label }
            switch item.status {
            case .completed: return "刚刚搞定"
            case .error: return "刚刚报错"
            case .waiting: return "等你拍板"
            default: return item.status.label
            }
        }()

        return HStack(spacing: 4.5) {
            if item.status == .running {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(item.status.badgeColor)
                    .frame(width: 6, height: 6)
            }

            Text(badgeText)
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundColor(item.status.badgeColor)
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 3.5)
        .background(item.status.badgeColor.opacity(0.16))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(item.status.badgeColor.opacity(0.35), lineWidth: 0.8)
        )
    }
}
