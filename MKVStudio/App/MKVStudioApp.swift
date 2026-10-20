import SwiftUI

@main
struct MKVStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @StateObject private var owner = AppOwner()
    private var state: AppState { owner.state }
    var body: some Scene {
        Window("MKVStudio", id: "main") {
            RootSplitView(state: state)
                .preferredColorScheme(state.appearance == "light" ? .light : state.appearance == "dark" ? .dark : nil)
                .task { delegate.state = state; await state.bootstrap() }
        }
        .defaultSize(width: 1380, height: 860)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { ToolbarCommands(state: state) }
        Settings { StudioSettings(state: state) }
            .windowResizability(.contentSize)
    }
}

struct StudioSettings: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Настройки").font(.title2.weight(.semibold))
            GroupBox("Оформление") {
                Picker("Тема", selection: $state.appearance) {
                    Text("Системная").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }.padding(12)
            }
            GroupBox("Консольные утилиты") {
              VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Версия", value: state.toolVersion)
                Divider()
                ForEach(ToolLocator.names, id: \.self) { name in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.callout.monospaced())
                            Text(state.toolPath(name)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(state.toolPath(name))
                        }
                        Spacer()
                        Button("Выбрать…") { state.chooseTool(name) }
                    }
                }
                HStack {
                    Button("Выбрать папку…", action: state.chooseTools)
                    Button("Проверить") { Task { await state.detectTools() } }
                }
                Text("Установщик MKVStudio добавляет недостающие консольные утилиты. Здесь можно выбрать собственную версию каждой программы.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
              }.padding(12)
            }
            HStack {
                Text("MKVStudio 0.3.0").foregroundStyle(.secondary)
                Spacer()
                Link("Документация mkvmerge", destination: URL(string: "https://man.archlinux.org/man/mkvmerge.1.en")!)
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(width: 700, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// Keeps observable workspace identity stable on macOS 14 and the command-line SDK.
@MainActor final class AppOwner: ObservableObject { let state = AppState() }

@MainActor final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.saveWorkspace()
        guard let state, state.activeJob != nil || state.queueRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Обработка ещё не завершена"
        alert.informativeText = "Можно продолжить работу или отменить текущее задание и выйти. Исходные файлы сохранятся."
        alert.addButton(withTitle: "Продолжить работу")
        alert.addButton(withTitle: "Отменить и выйти")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        state.stopQueue()
        Task {
            while state.activeJob != nil { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
