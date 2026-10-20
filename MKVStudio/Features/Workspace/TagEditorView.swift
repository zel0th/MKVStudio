import SwiftUI

struct TagEditorView: View {
    @Bindable var state: AppState
    var body: some View {
        Group {
            if state.files.isEmpty {
                ContentUnavailableView("Добавьте исходный файл", systemImage: "tag", description: Text("Здесь можно изменить название произведения и стандартные теги Matroska."))
            } else {
                Form {
                    Section {
                        Text("Редактор тегов").font(.title2.weight(.semibold))
                        Text("Изменения сохранятся в результате сборки. Исходные файлы сохраняются.").foregroundStyle(.secondary)
                        TextField("Название контейнера", text: $state.project.title)
                        Text("Это внутреннее название файла, которое показывают проигрыватели.").foregroundStyle(.secondary)
                    }
                    Section("Произведение · фильм или эпизод") {
                        Picker("Язык тегов", selection: Binding(get: { state.project.tagEdits?.language ?? "und" }, set: state.setTagLanguage)) {
                            Text("Не указан").tag("und")
                            Text("Русский").tag("ru")
                            Text("English").tag("en")
                            Text("日本語").tag("ja")
                            if let language = state.project.tagEdits?.language, !["und", "ru", "en", "ja"].contains(language) {
                                Text(language).tag(language)
                            }
                        }.disabled(state.isLoadingTags || state.project.tagEdits?.values.isEmpty == false)
                        Text("Значения первого исходного файла. Правки относятся ко всему произведению и выбранному языку. Несколько актёров, режиссёров или жанров — каждый с новой строки.").foregroundStyle(.secondary)
                        if state.isLoadingTags { ProgressView("Чтение тегов…") }
                        else if state.tagsSourceID != state.files.first?.id {
                            Button("Прочитать теги") { Task { await state.loadTags() } }
                        } else {
                            ForEach(MatroskaTagField.all) { field in
                                VStack(alignment: .leading, spacing: 6) {
                                    TextField(field.title, text: Binding(get: {
                                        state.project.tagEdits?.values[field.id] ?? state.tagValues[field.id] ?? ""
                                    }, set: { state.setTag(field.id, value: $0) }), axis: .vertical)
                                        .lineLimit(field.multiline ? 3...6 : 1...4)
                                        .help(field.id)
                                    if !field.hint.isEmpty { Text(field.hint).foregroundStyle(.secondary) }
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                    Section {
                        HStack {
                            Text("Изменено полей: \(state.project.tagEdits?.values.count ?? 0)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Сбросить правки тегов") {
                                state.project.tagEdits?.values = [:]
                            }.disabled(state.project.tagEdits?.values.isEmpty != false)
                        }
                        Text("Незаполненное изменённое поле удаляет тег. Переводы, теги дорожек и остальные свойства сохраняются. Страна / место съёмки — стандартное поле RECORDING_LOCATION; отдельного тега «страна производства» в Matroska нет.").foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
        }
        .task(id: state.files.first?.id) { await state.loadTags() }
    }
}
