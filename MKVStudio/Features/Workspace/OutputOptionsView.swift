import SwiftUI

struct OutputOptionsView: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            Section {
                Picker("Обработка файлов", selection: Binding(get: { state.project.mode }, set: { state.project.assemblyMode = $0 })) {
                    ForEach(AssemblyMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(state.project.mode == .append ? "Файлы идут друг за другом. Дорожки сопоставляются по порядку внутри каждого файла; их кодеки и параметры должны совпадать. Имена и HDR-настройки берутся из первого файла." : "Видео, аудио и субтитры из разных источников собираются в один контейнер.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Склейка") }
            Section("Порядок файлов") {
                ForEach(Array(state.files.enumerated()), id: \.element.id) { index, file in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.fileName).lineLimit(1)
                            Text(file.tracks.filter(\.included).map { $0.kind.title }.joined(separator: " · ")).font(.body).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(file.duration).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Button { state.moveFile(file.id, offset: -1) } label: { Image(systemName: "arrow.up") }.help("Раньше").disabled(index == 0)
                        Button { state.moveFile(file.id, offset: 1) } label: { Image(systemName: "arrow.down") }.help("Позже").disabled(index == state.files.count - 1)
                    }.buttonStyle(.borderless)
                }
                if state.files.isEmpty { Button("Добавить файлы…", action: state.importFiles) }
            }
            Section("Разбиение результата") {
                Picker("Режим", selection: splitBinding(\.mode)) {
                    ForEach(SplitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if state.project.split.enabled {
                    TextField("Параметры", text: splitBinding(\.value), prompt: Text(state.project.split.mode.example))
                    Text("Пример: \(state.project.split.mode.example)").font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                    TextField("Максимум частей", value: splitBinding(\.maxFiles), format: .number.grouping(.never))
                    Text("0 — без ограничения").font(.body).foregroundStyle(.secondary)
                    Toggle("Связать части между собой", isOn: splitBinding(\.linkFiles))
                    if state.project.split.mode == .parts {
                        Text("Знак + перед следующим диапазоном объединяет его с предыдущим. Пустое начало означает конец предыдущего фрагмента, пустой конец — конец файла.").font(.body).foregroundStyle(.secondary)
                    }
                    Text("Разрезы проходят по ключевым кадрам: время и размер могут отличаться от заданных. Части part-001.mkv, part-002.mkv… появятся в новой папке .parts.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
    private func splitBinding<T>(_ key: WritableKeyPath<SplitOptions, T>) -> Binding<T> {
        Binding(get: { state.project.split[keyPath: key] }, set: { value in
            var split = state.project.split; split[keyPath: key] = value; state.project.splitOptions = split
        })
    }
}
