import SwiftUI

struct ToolbarCommands: Commands {
    var state: AppState
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Добавить файлы…", action: state.importFiles).keyboardShortcut("o").disabled(state.isImporting)
            Button("Открыть проект…", action: state.openProject).keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Сохранить проект…", action: state.saveProject).keyboardShortcut("s")
        }
        CommandMenu("Сборка") {
            Button("Собрать MKV") { state.enqueue(start: true) }.keyboardShortcut(.return, modifiers: .command).disabled(!state.canMux)
            Button("Добавить в очередь") { state.enqueue(start: false) }.disabled(!state.canMux)
            Divider()
            Button("Запустить очередь", action: state.startQueue).disabled(state.queueRunning || state.waitingCount == 0)
            Button("Остановить очередь", action: state.stopQueue).disabled(!state.queueRunning)
            Divider()
            Button("Извлечь выбранную дорожку…", action: state.extractSelectedTrack).disabled(state.selectedTrack == nil || state.trackSource?.isMatroska != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Показать / скрыть свойства") { state.isInspectorVisible.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
