import SwiftUI

struct KinopoiskSearchContext: Identifiable {
    let id: UUID
    let generation: UUID
    let query: String
}

struct KinopoiskSearchView: View {
    @Bindable var state: AppState
    let context: KinopoiskSearchContext
    @Environment(\.dismiss) private var dismiss
    @StudioViewState private var model: KinopoiskSearchModel
    init(state: AppState, context: KinopoiskSearchContext, client: KinopoiskClient? = nil) {
        self.state = state; self.context = context
        // Initial query belongs to this individual search sheet; later edits are local.
        let model = KinopoiskSearchModel(query: context.query); model.client = client
        _model = StudioViewState(initialValue: model)
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Найти информацию").font(.title2.weight(.semibold))
                Text("Kinopoisk Unofficial API · данные на русском языке").foregroundStyle(.secondary)
                HStack {
                    TextField("Название, ссылка Кинопоиска или ID", text: $model.query)
                        .textFieldStyle(.roundedBorder).onSubmit { if !model.busy { model.search() } }
                    TextField("Год", text: $model.year).textFieldStyle(.roundedBorder).frame(width: 75)
                    Button("Найти") { model.search() }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(20)
            Divider()
            HSplitView {
                resultList.frame(minWidth: 230, idealWidth: 260, maxWidth: 300)
                selectionPanel.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small); Text(model.applying ? "Перенос данных…" : "Загрузка…").foregroundStyle(.secondary) }
                Spacer()
                Button("Отмена") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Перенести выбранное") {
                    model.apply(state: state, sourceID: context.id, generation: context.generation) { dismiss() }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy || model.details == nil || (model.selection.fields.isEmpty && !model.selection.poster && !model.selection.containerTitle))
            }.padding(16)
        }
        .frame(width: 900, height: 680)
        .onDisappear { model.cancel() }
        .onChange(of: state.files.first?.id) { if state.files.first?.id != context.id { model.cancel(); dismiss() } }
    }
    private var resultList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.results) { film in
                    Button { model.select(film, state: state) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(film.title).font(.headline).lineLimit(3)
                            Text("\(film.year.map(String.init) ?? "Год не указан") · \(film.kind)").foregroundStyle(.secondary)
                            if let original = film.nameOriginal, original != film.title { Text(original).foregroundStyle(.secondary).lineLimit(2) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(model.details?.film.id == film.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.applying)
                }
            }
            if model.searched && model.results.isEmpty { Text("Ничего не найдено. Уточните название или вставьте ссылку.").foregroundStyle(.secondary).padding() }
            if model.totalPages > 1 {
                HStack {
                    Button { model.search(page: model.page - 1) } label: { Image(systemName: "chevron.left") }.help("Предыдущая страница").disabled(model.page == 1 || model.busy)
                    Text("\(model.page) / \(model.totalPages)").monospacedDigit()
                    Button { model.search(page: model.page + 1) } label: { Image(systemName: "chevron.right") }.help("Следующая страница").disabled(model.page >= model.totalPages || model.busy)
                }.padding(12)
            }
        }
    }
    @ViewBuilder private var selectionPanel: some View {
        if let details = model.details {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(details.film.title).font(.title2.weight(.semibold))
                    Text(details.film.isSeries ? "Теги всего сериала · уровень Matroska 70. Название и описание отдельной серии не подставляются." : "Теги фильма · уровень Matroska 50.")
                        .foregroundStyle(.secondary)
                    if let countries = details.film.countries, !countries.isEmpty {
                        Text("Страны производства: \(countries.map(\.country).joined(separator: ", ")). Для справки; в «место съёмки» не переносится.").foregroundStyle(.secondary)
                    }
                    Toggle("Заполнять только пустые поля", isOn: $model.selection.onlyEmpty)
                    HStack {
                        Button("Выбрать все теги") { model.selection.fields = Set(details.fields.keys) }
                        Button("Снять выбор тегов") { model.selection.fields = [] }
                    }
                    ForEach(MatroskaTagField.all.filter { details.fields[$0.id] != nil }) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(field.title, isOn: Binding(get: { model.selection.fields.contains(field.id) }, set: { selected in
                                if selected { model.selection.fields.insert(field.id) } else { model.selection.fields.remove(field.id) }
                            })).font(.headline)
                            Text(details.fields[field.id] ?? "").textSelection(.enabled)
                            if let old = model.baseline[field.id], !old.isEmpty {
                                Text("Сейчас: \(old)").foregroundStyle(.secondary).lineLimit(3)
                                if model.selection.onlyEmpty { Text("Поле заполнено — будет сохранено.").foregroundStyle(.secondary) }
                            }
                        }
                        Divider()
                    }
                    if details.film.nameRu != nil {
                        Toggle("Также изменить название контейнера", isOn: $model.selection.containerTitle)
                        Text("Сейчас: \(state.project.title.isEmpty ? "не указано" : state.project.title)").foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Group {
                            if let image = model.preview { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                            else { Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.secondary) }
                        }.frame(width: 120, height: 170)
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Добавить постер во вложения", isOn: $model.selection.poster)
                                .disabled(KinopoiskClient.posterURL(details.film.posterUrl) == nil)
                            Text("Полный постер загрузится после нажатия «Перенести выбранное». Существующие вложения сохраняются.").foregroundStyle(.secondary)
                            if let error = model.posterError { Text("Предпросмотр: \(error)").foregroundStyle(.orange) }
                        }
                    }
                    Text("Переносятся только доступные русские значения. Файл изменится при сборке; исходник сохраняется.").foregroundStyle(.secondary)
                    Link("Карточка на Кинопоиске", destination: URL(string: "https://www.kinopoisk.ru/\(details.film.isSeries ? "series" : "film")/\(details.film.id)/")!)
                }.padding(20)
            }.disabled(model.applying)
        } else {
            ContentUnavailableView("Выберите произведение", systemImage: "magnifyingglass", description: Text("Найдите фильм или сериал, затем отметьте теги и постер для переноса."))
        }
    }
}
