import AppKit
import SwiftUI

struct SkinStatus: Decodable {
    let enabled: Bool
    let port: Int?
    let themeDir: String?
    let themeId: String?
    let themeName: String?
    let conversationOpacity: Double
    let running: Bool
    let skinActive: Bool
    let supervisorRunning: Bool
    let doubaoVersion: String
}

struct ThemeSummary: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let directory: String
    let background: String
    let backgroundPath: String
    let revision: String

    var backgroundURL: URL {
        URL(fileURLWithPath: backgroundPath)
    }
}

private struct InvalidThemeSummary: Decodable {
    let entry: String
    let reason: String
}

private struct ThemeLibrary: Decodable {
    let schema: String
    let directory: String
    let themes: [ThemeSummary]
    let invalid: [InvalidThemeSummary]
}

private enum ManagerError: LocalizedError {
    case missingRuntime
    case commandFailed(String)
    case invalidStatus
    case invalidThemeLibrary

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            return "应用内的皮肤运行时不完整，请重新安装 Doubao Skin。"
        case .commandFailed(let message):
            return message.isEmpty ? "操作没有完成。" : message
        case .invalidStatus:
            return "无法读取 Doubao Skin 状态。"
        case .invalidThemeLibrary:
            return "无法读取主题库，请确认其中的主题文件夹结构完整。"
        }
    }
}

private enum SkinManager {
    static var scriptURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("manage-doubao-skin-macos.sh")
    }

    static func run(_ arguments: [String]) async throws -> String {
        guard let scriptURL, FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw ManagerError.missingRuntime
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [scriptURL.path] + arguments
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: ManagerError.commandFailed(text))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func status() async throws -> SkinStatus {
        let text = try await run(["status"])
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(SkinStatus.self, from: data) else {
            throw ManagerError.invalidStatus
        }
        return value
    }

    static func themeLibrary() async throws -> ThemeLibrary {
        let text = try await run(["list-themes"])
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(ThemeLibrary.self, from: data),
              value.schema == "doubao-skin-theme-library/1" else {
            throw ManagerError.invalidThemeLibrary
        }
        return value
    }
}

@MainActor
final class SkinViewModel: ObservableObject {
    @Published private(set) var status: SkinStatus?
    @Published private(set) var themes: [ThemeSummary] = []
    @Published var selectedTheme: ThemeSummary?
    @Published var conversationOpacity = 0.66
    @Published private(set) var invalidThemeCount = 0
    @Published private(set) var libraryDirectory = ""
    @Published var message = "正在读取主题库和状态…"
    @Published var busy = false
    @Published var showDisableConfirmation = false
    private var didLoad = false

    var enabled: Bool { status?.enabled == true }
    var canApply: Bool { selectedTheme != nil && !busy }
    var selectedThemeName: String { selectedTheme?.name ?? "未选择主题" }
    var conversationOpacityPercent: Int {
        Int((conversationOpacity * 100).rounded())
    }

    var statusTitle: String {
        guard let status else { return "读取中" }
        if status.enabled && status.supervisorRunning {
            return status.skinActive ? "皮肤已应用" : "常驻已启用"
        }
        return "未启用"
    }

    var statusDetail: String {
        guard let status else { return "请稍候" }
        if status.enabled {
            if status.skinActive {
                return "豆包正在使用 \(status.themeName ?? "当前主题")"
            }
            return "下次正常打开豆包时会自动恢复 \(status.themeName ?? "当前主题")"
        }
        return "从主题库选择一款主题即可启用"
    }

    var applyButtonTitle: String {
        guard let selectedTheme else { return "主题库中暂无可用主题" }
        if isActive(selectedTheme) {
            return status?.skinActive == true
                ? "重新应用 \(selectedTheme.name)"
                : "恢复 \(selectedTheme.name)"
        }
        return enabled ? "切换到 \(selectedTheme.name)" : "启用 \(selectedTheme.name)"
    }

    var applyButtonIcon: String {
        guard let selectedTheme else { return "photo.badge.exclamationmark" }
        return isActive(selectedTheme) ? "arrow.clockwise" : "sparkles"
    }

    func isActive(_ theme: ThemeSummary) -> Bool {
        guard status?.enabled == true else { return false }
        if let themeDir = status?.themeDir {
            return standardizedPath(themeDir) == standardizedPath(theme.directory)
        }
        return status?.themeId == theme.id
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true
        busy = true
        Task {
            do {
                try await reloadData(preferActiveTheme: true)
                message = enabled
                    ? "主题库已就绪。"
                    : "选择一个主题后即可启用；添加主题请打开主题库文件夹。"
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    func selectTheme(_ theme: ThemeSummary) {
        selectedTheme = theme
        message = isActive(theme)
            ? "\(theme.name) 是当前主题。"
            : "已选择 \(theme.name)，点击下方按钮切换。"
    }

    func refreshLibrary() {
        guard !busy else { return }
        busy = true
        message = "正在重新扫描主题库…"
        Task {
            do {
                try await reloadData(preferActiveTheme: false)
                if invalidThemeCount > 0 {
                    message = "找到 \(themes.count) 个有效主题；已忽略 \(invalidThemeCount) 个无效项目。"
                } else {
                    message = "已刷新，共 \(themes.count) 个有效主题。"
                }
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    func apply() {
        guard let selectedTheme else {
            message = "主题库中没有可用主题。"
            return
        }
        runOperation(progress: "正在校验并应用 \(selectedTheme.name)…") {
            try await SkinManager.run([
                "activate-library", "--theme-dir", selectedTheme.directory,
            ])
        }
    }

    func openDoubao() {
        runOperation(progress: "正在打开豆包…") {
            try await SkinManager.run(["open"])
        }
    }

    func disable() {
        showDisableConfirmation = false
        runOperation(progress: "正在停用常驻并恢复官方外观…") {
            try await SkinManager.run(["disable"])
        }
    }

    func revealThemes() {
        runOperation(progress: "正在打开主题库…", reloadAfter: false) {
            try await SkinManager.run(["reveal-themes"])
        }
    }

    func commitConversationOpacity() {
        guard enabled, !busy else { return }
        let normalized = min(1, max(0, conversationOpacity))
        conversationOpacity = normalized
        let value = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            normalized
        )
        runOperation(progress: "正在调整对话页蒙版…") {
            try await SkinManager.run([
                "set-conversation-opacity", "--conversation-opacity", value,
            ])
        }
    }

    private func runOperation(
        progress: String,
        reloadAfter: Bool = true,
        operation: @escaping () async throws -> String
    ) {
        guard !busy else { return }
        busy = true
        message = progress
        Task {
            do {
                let result = try await operation()
                if reloadAfter {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    try await reloadData(preferActiveTheme: false)
                }
                message = result.isEmpty ? "操作完成。" : result
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func reloadData(preferActiveTheme: Bool) async throws {
        let latestLibrary = try await SkinManager.themeLibrary()
        let latestStatus = try await SkinManager.status()
        let previousSelection = selectedTheme

        themes = latestLibrary.themes
        invalidThemeCount = latestLibrary.invalid.count
        libraryDirectory = latestLibrary.directory
        status = latestStatus
        conversationOpacity = min(1, max(0, latestStatus.conversationOpacity))

        let activeTheme = latestLibrary.themes.first {
            if let themeDir = latestStatus.themeDir {
                return standardizedPath($0.directory) == standardizedPath(themeDir)
            }
            return $0.id == latestStatus.themeId
        }
        let retainedSelection = previousSelection.flatMap { selected in
            latestLibrary.themes.first { $0.directory == selected.directory }
        }
        if preferActiveTheme, let activeTheme {
            selectedTheme = activeTheme
        } else {
            selectedTheme = retainedSelection ?? activeTheme ?? latestLibrary.themes.first
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private struct ThemeLibraryCard: View {
    let theme: ThemeSummary
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    if let image = NSImage(contentsOf: theme.backgroundURL) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 206, height: 116)
                            .clipped()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                            .frame(width: 206, height: 116)
                    }
                    if isActive {
                        Label("使用中", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.ultraThickMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .frame(width: 206, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(theme.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .padding(8)
            .frame(width: 222, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.13)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.68),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择主题 \(theme.name)")
        .accessibilityValue(isActive ? "当前正在使用" : (isSelected ? "已选择" : "未选择"))
    }
}

struct ContentView: View {
    @ObservedObject var model: SkinViewModel

    private let projectURL = URL(string: "https://github.com/just-cyan-lu/doubao-skin")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.13))
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Doubao Skin")
                        .font(.title2.weight(.bold))
                    Text("豆包 macOS 主题管理器")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("豆包 \(model.status?.doubaoVersion ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(model.enabled ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusTitle)
                        .font(.headline)
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("主题库")
                        .font(.title3.weight(.semibold))
                    Text("把完整主题文件夹粘贴到主题库，再点刷新即可看到缩略图。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.revealThemes()
                } label: {
                    Label("打开主题库", systemImage: "folder")
                }
                .disabled(model.busy)
                Button {
                    model.refreshLibrary()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)
            }

            Group {
                if model.themes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("主题库中还没有有效主题")
                            .font(.headline)
                        Text("点“打开主题库”，粘贴包含 theme.json 和背景图的完整文件夹，然后点“刷新”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 430)
                    }
                    .frame(maxWidth: .infinity, minHeight: 178)
                    .background(
                        Color(nsColor: .controlBackgroundColor).opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            ForEach(model.themes) { theme in
                                ThemeLibraryCard(
                                    theme: theme,
                                    isSelected: model.selectedTheme == theme,
                                    isActive: model.isActive(theme)
                                ) {
                                    model.selectTheme(theme)
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 8)
                    }
                    .frame(minHeight: 178)
                }
            }

            if model.invalidThemeCount > 0 {
                Label(
                    "已隐藏 \(model.invalidThemeCount) 个结构不完整或校验失败的项目。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("对话页蒙版不透明度", systemImage: "square.stack.3d.up.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(model.conversationOpacityPercent)%")
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $model.conversationOpacity,
                    in: 0...1,
                    step: 0.01,
                    onEditingChanged: { editing in
                        if !editing {
                            model.commitConversationOpacity()
                        }
                    }
                )
                .disabled(!model.enabled || model.busy)
                .accessibilityLabel("对话页蒙版不透明度")
                Text("只影响有聊天内容时覆盖在背景图上的阅读蒙版；首页、菜单和发送框不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            Button {
                model.apply()
            } label: {
                Label(model.applyButtonTitle, systemImage: model.applyButtonIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApply)

            HStack {
                Button("打开豆包") { model.openDoubao() }
                    .disabled(model.busy)
                Spacer()
                Button("停用并恢复", role: .destructive) {
                    model.showDisableConfirmation = true
                }
                .disabled(!model.enabled || model.busy)
            }

            HStack(alignment: .top, spacing: 8) {
                if model.busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Text("© 2026 陆思源Cyan · AGPL-3.0-only · 无担保；传播或售卖须保留版权并提供源码")
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer()
                Link("GitHub 项目", destination: projectURL)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 820, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.load() }
        .alert("停用 Doubao Skin？", isPresented: $model.showDisableConfirmation) {
            Button("取消", role: .cancel) {}
            Button("停用并恢复", role: .destructive) { model.disable() }
        } message: {
            Text("常驻服务会被移除；主题库中的文件会保留，之后可以再次启用。")
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: SkinViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusTitle)
        Text(model.statusDetail)
        Divider()
        Button("打开管理器") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "manager")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("打开豆包") {
            model.openDoubao()
        }
        Button(model.applyButtonTitle) {
            model.apply()
        }
        .disabled(!model.canApply)
        Divider()
        Button("打开主题库") {
            model.revealThemes()
        }
        Button("刷新主题库") {
            model.refreshLibrary()
        }
        .disabled(model.busy)
        Divider()
        Button("退出 Doubao Skin") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

final class DoubaoSkinAppDelegate: NSObject, NSApplicationDelegate {
    private var managerWindowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        managerWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Doubao Skin" else {
                return
            }
            DispatchQueue.main.async {
                let managerIsVisible = NSApp.windows.contains {
                    $0.title == "Doubao Skin" && $0.isVisible
                }
                if !managerIsVisible {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let managerWindowCloseObserver {
            NotificationCenter.default.removeObserver(managerWindowCloseObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct DoubaoSkinApp: App {
    @NSApplicationDelegateAdaptor(DoubaoSkinAppDelegate.self) private var appDelegate
    @StateObject private var model = SkinViewModel()

    var body: some Scene {
        Window("Doubao Skin", id: "manager") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent(model: model)
                .task { model.load() }
        } label: {
            Image(systemName: model.enabled ? "paintbrush.pointed.fill" : "paintbrush.pointed")
                .accessibilityLabel("Doubao Skin")
        }
        .menuBarExtraStyle(.menu)
    }
}
