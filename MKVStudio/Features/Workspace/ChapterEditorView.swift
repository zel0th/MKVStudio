import SwiftUI

struct ChapterEditorView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Главы").font(.title2.weight(.semibold))
                        Text("Отметки, названия и вложенные главы").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Импорт") {
                        Button("XML или текст…", action: state.importChapterDocument)
                        Button("Из выбранного MKV") { Task { await state.extractChapters() } }
                            .disabled(state.selectedFile?.isMatroska != true || state.tools == nil || state.isLoadingChapters)
                    }
                    Button("Экспорт XML…", action: state.exportChapters).disabled(state.chapterRows.isEmpty)
                }
                Toggle("Использовать главы редактора в сборке", isOn: Binding(get: { state.project.useChapterEditor ?? false }, set: { state.project.useChapterEditor = $0 }))
                HStack {
                    Picker("Источник для импорта", selection: $state.selectedFileID) {
                        Text("Выберите файл").tag(nil as UUID?)
                        ForEach(state.files) { Text($0.fileName).tag(Optional($0.id)) }
                    }.labelsHidden().frame(maxWidth: 330)
                    if state.isLoadingChapters { ProgressView().controlSize(.small) }
                    Spacer()
                    if let document = state.project.chapterDocument {
                        Picker("Редакция", selection: Binding(get: { state.selectedEditionID ?? document.editions.first?.id }, set: { state.selectedEditionID = $0; state.selectedChapterID = nil })) {
                            ForEach(Array(document.editions.enumerated()), id: \.element.id) { index, edition in Text("Редакция \(index + 1)").tag(Optional(edition.id)) }
                        }.frame(maxWidth: 200)
                        Button(action: state.addEdition) { Image(systemName: "plus.rectangle.on.rectangle") }.help("Добавить редакцию")
                    }
                }
                ChapterTimeline(rows: state.chapterRows, duration: state.timelineDuration, selected: state.selectedChapterID) { state.selectedChapterID = $0 }
            }.padding(22)
            Divider()
            if state.chapterRows.isEmpty {
                ContentUnavailableView("Добавьте первую главу", systemImage: "list.bullet.indent", description: Text("Создайте главы вручную или импортируйте их из файла."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(state.chapterRows, selection: $state.selectedChapterID) {
                    TableColumn("Начало") { row in Text(row.entry.start).font(.callout.monospacedDigit()) }.width(min: 130, ideal: 160)
                    TableColumn("Название") { row in
                        HStack(spacing: 6) {
                            if row.depth > 0 { Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary) }
                            Text(row.entry.name.isEmpty ? "Без названия" : row.entry.name)
                        }.padding(.leading, CGFloat(row.depth * 12))
                    }
                    TableColumn("Язык") { row in Text(row.entry.language).foregroundStyle(.secondary) }.width(60)
                }
            }
            Divider()
            HStack {
                Button(action: { state.addChapter() }) { Label("Глава", systemImage: "plus") }
                Button(action: { state.addChapter(child: true) }) { Label("Вложенная", systemImage: "arrow.turn.down.right") }.disabled(state.selectedChapter == nil)
                Button(action: state.removeChapter) { Image(systemName: "minus") }.help("Удалить главу и вложенные главы").disabled(state.selectedChapter == nil)
                Spacer()
                Button { state.moveChapter(-1) } label: { Image(systemName: "arrow.up") }.help("Выше").disabled(state.selectedChapter == nil)
                Button { state.moveChapter(1) } label: { Image(systemName: "arrow.down") }.help("Ниже").disabled(state.selectedChapter == nil)
            }.padding(16)
        }
    }
}

private struct ChapterTimeline: View {
    let rows: [ChapterEntry.Row]
    let duration: Double
    let selected: UUID?
    let select: (UUID) -> Void
    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.blue.opacity(0.12)).frame(height: 28)
                    ForEach(rows) { row in
                        Button { select(row.id) } label: {
                            RoundedRectangle(cornerRadius: 2).fill(row.id == selected ? Color.accentColor : Color.secondary.opacity(0.5)).frame(width: row.id == selected ? 5 : 3, height: row.depth == 0 ? 24 : 15)
                                .frame(width: 14, height: 32).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .offset(x: max(0, min(geometry.size.width - 14, geometry.size.width * row.entry.seconds / duration - 7)))
                            .help("\(row.entry.start) · \(row.entry.name)").accessibilityLabel("Глава: \(row.entry.name), \(row.entry.start)")
                    }
                }.frame(height: 32)
            }.frame(height: 32)
            HStack { Text("00:00:00"); Spacer(); Text(String(MediaTime.format(Int64(min(duration, 35_999_999) * 1e9)).prefix(8))) }
                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct ChapterInspector: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            if let chapter = state.selectedChapter {
                Section("Глава") {
                    TextField("Название", text: binding(chapter, \.name))
                    TextField("Начало", text: binding(chapter, \.start))
                    TextField("Конец", text: binding(chapter, \.end), prompt: Text("Не задан"))
                    TextField("Язык", text: binding(chapter, \.language))
                    Text("Время: ЧЧ:ММ:СС.ннн. Конец можно оставить пустым.").font(.body).foregroundStyle(.secondary)
                }
                Section("Положение на шкале") {
                    Slider(value: Binding(get: { min(chapter.seconds, state.timelineDuration) }, set: { seconds in state.updateChapter(chapter.id) { $0.start = MediaTime.format(Int64(seconds * 1e9)) } }), in: 0...state.timelineDuration)
                        .accessibilityLabel("Начало главы на временной шкале")
                    Text(chapter.start).font(.callout.monospacedDigit())
                }
            } else { Text("Выберите главу в таблице или на временной шкале.").foregroundStyle(.secondary) }
            Section {
                Text("Редактор сохраняет редакции, вложенность, UID, флаги и дополнительные названия импортированного XML. Изменения войдут в новый MKV при сборке.").font(.body).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func binding(_ entry: ChapterEntry, _ key: WritableKeyPath<ChapterEntry, String>) -> Binding<String> {
        Binding(get: { state.selectedChapter?[keyPath: key] ?? entry[keyPath: key] }, set: { value in state.updateChapter(entry.id) { $0[keyPath: key] = value } })
    }
}
