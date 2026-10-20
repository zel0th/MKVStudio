import SwiftUI

struct InspectorView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.selectedSection == .queue ? "Задание" : "Свойства").font(.headline)
                Spacer()
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            if state.selectedSection == .queue, let job = state.selectedJob {
                Form {
                    Section("Результат") {
                        LabeledContent("Статус", value: job.state.title)
                        Text(job.output.path).font(.body).textSelection(.enabled)
                        if job.state == .finished || job.state == .warning { Button("Показать в Finder") { state.reveal(job.output) } }
                    }
                    Section("Инструмент") { Text(job.executable.lastPathComponent).font(.callout.monospaced()) }
                }.formStyle(.grouped)
            } else if state.selectedSection == .queue {
                ContentUnavailableView("Нет задания", systemImage: "list.bullet.rectangle", description: Text("Добавьте сборку в очередь."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.selectedSection == .chapters {
                ChapterInspector(state: state)
            } else {
                Form {
                    Section("Контейнер") { TextField("Название", text: $state.project.title, prompt: Text("Без названия")) }
                    if let track = state.selectedTrack {
                        Section(track.kind.title) {
                            LabeledContent("Кодек", value: track.codec)
                            TextField("Имя", text: trackBinding(track, \.name))
                            TextField("Код языка", text: trackBinding(track, \.language))
                            Menu("Выбрать язык") {
                                ForEach([("ru", "Русский"), ("en", "Английский"), ("ja", "Японский"), ("de", "Немецкий"), ("fr", "Французский"), ("und", "Не указан")], id: \.0) { code, title in
                                    Button(title) { state.updateTrack(track.id) { $0.language = code } }
                                }
                            }
                            Toggle("Включить в сборку", isOn: trackBinding(track, \.included))
                            Toggle("По умолчанию", isOn: trackBinding(track, \.defaultTrack))
                            Toggle("Принудительно", isOn: trackBinding(track, \.forced))
                        }
                        Section("Синхронизация") {
                            TextField("Задержка, мс", value: trackBinding(track, \.delayMS), format: .number.grouping(.never))
                            Text("Положительное значение сдвигает дорожку вперёд.").font(.body).foregroundStyle(.secondary)
                        }
                        if track.kind == .video { HDRInspector(state: state, track: track) }
                        if let source = state.trackSource {
                            Section("Источник") {
                                Text(source.fileName).font(.callout).textSelection(.enabled)
                                LabeledContent("Длительность", value: source.duration)
                                LabeledContent("Размер", value: source.fileSize)
                                Button("Извлечь дорожку…", action: state.extractSelectedTrack).disabled(!source.isMatroska || state.tools == nil)
                            }
                        }
                    } else {
                        Section { Text("Выберите дорожку, чтобы настроить её язык, флаги и синхронизацию.").foregroundStyle(.secondary) }
                    }
                }.formStyle(.grouped)
            }
        }.background(.regularMaterial)
    }
    private func trackBinding<Value>(_ track: TrackRow, _ key: WritableKeyPath<TrackRow, Value>) -> Binding<Value> {
        Binding(get: { state.tracks.first(where: { $0.id == track.id })?[keyPath: key] ?? track[keyPath: key] }, set: { value in state.updateTrack(track.id) { $0[keyPath: key] = value } })
    }
}
