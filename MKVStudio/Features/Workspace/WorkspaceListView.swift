import SwiftUI

struct AttachmentsView: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Вложения").font(.title2.weight(.semibold))
                        Text("Обложки, шрифты и метаданные.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Добавить…", action: state.addAttachments)
                }
            }
            Section("Добавленные вложения") {
                if state.project.attachments.isEmpty { Text("Добавьте обложку или шрифты для субтитров.").foregroundStyle(.secondary) }
                ForEach($state.project.attachments) { $item in
                    HStack {
                        Image(systemName: item.mimeType.hasPrefix("image/") ? "photo" : "doc")
                        VStack(alignment: .leading) {
                            TextField("Имя вложения", text: $item.name)
                            Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                        Button { state.project.attachments.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }.help("Убрать вложение")
                    }
                }
            }
            ForEach($state.project.files) { $file in
                Section(file.fileName) {
                    Toggle("Сохранить главы (\(file.chapterCount))", isOn: $file.includeChapters).disabled(state.project.chaptersURL != nil || state.project.useChapterEditor == true)
                    Toggle("Сохранить теги", isOn: $file.includeTags)
                    ForEach($file.attachments) { $attachment in
                        Toggle(isOn: $attachment.included) {
                            VStack(alignment: .leading) {
                                Text(attachment.name)
                                Text("\(attachment.mimeType) · \(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Внешний файл глав") {
                if state.project.useChapterEditor == true { Text("Сейчас используются главы из редактора.").foregroundStyle(.secondary) }
                HStack {
                    Text(state.project.chaptersURL?.lastPathComponent ?? "Используются главы исходных файлов").foregroundStyle(.secondary)
                    Spacer()
                    Button("Выбрать…", action: state.chooseChapters)
                    if state.project.chaptersURL != nil { Button("Убрать") { state.project.chaptersURL = nil } }
                }
            }
        }.formStyle(.grouped)
    }
}

struct InformationView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Информация о файле").font(.title2.weight(.semibold))
            HStack {
                Picker("Файл", selection: $state.selectedFileID) {
                    ForEach(state.files) { file in Text(file.fileName).tag(Optional(file.id)) }
                }
                Button("Прочитать") { Task { await state.readInfo() } }.disabled(state.selectedFile == nil || state.isReadingInfo || state.tools == nil)
                if state.isReadingInfo { ProgressView().controlSize(.small) }
            }
            if let file = state.selectedFile {
                HStack(spacing: 18) {
                    Label(file.container, systemImage: "doc.zipper")
                    Label(file.duration, systemImage: "clock")
                    Text(file.fileSize)
                }.font(.callout).foregroundStyle(.secondary)
                Button("Сохранить правки заголовков в копию…", action: state.editHeaders).disabled(!file.isMatroska || state.tools == nil)
                    .help("Название, языки и флаги дорожек из инспектора; без изменения состава дорожек и задержек")
            }
            ScrollView([.vertical, .horizontal]) {
                Text(state.infoText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Text("Структура контейнера · mkvinfo").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
        .onChange(of: state.selectedFileID) {
            if state.trackSource?.id != state.selectedFileID { state.selectedTrackID = state.selectedFile?.tracks.first?.id }
            state.infoText = "Нажмите «Прочитать», чтобы получить структуру выбранного файла."
        }
    }
}

struct QueueView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Очередь заданий").font(.system(size: 25, weight: .semibold))
                    Text(state.queueRunning ? "Обработка файлов…" : "Каждое задание хранит свои настройки.").foregroundStyle(.secondary)
                }
                Spacer()
                if state.queueRunning {
                    Button("Остановить", action: state.stopQueue)
                } else {
                    Button("Запустить", action: state.startQueue).buttonStyle(.borderedProminent).disabled(state.waitingCount == 0)
                }
            }.padding(24)
            if state.jobs.isEmpty {
                ContentUnavailableView("Очередь пуста", systemImage: "list.bullet.rectangle", description: Text("Подготовьте дорожки и добавьте сборку в очередь."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $state.selectedJobID) {
                    ForEach(state.jobs) { job in
                        HStack(spacing: 14) {
                            Image(systemName: icon(job.state)).font(.title2).foregroundStyle(color(job.state)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(job.title).font(.headline).lineLimit(1)
                                Text(job.state.title).font(.caption).foregroundStyle(.secondary)
                                if job.state == .running { ProgressView(value: job.progress) }
                            }
                            Spacer()
                            if job.state == .running { Text(job.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                            if job.state == .waiting { Button { state.cancelWaiting(job.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Отменить задание") }
                            if job.state == .finished || job.state == .warning { Button { state.reveal(job.output) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Показать результат") }
                        }.padding(.vertical, 10).tag(job.id)
                    }
                }.listStyle(.inset)
            }
            if state.isLogVisible {
                Divider()
                ScrollView {
                    Text(state.selectedJob?.log.isEmpty == false ? state.selectedJob!.log : "Здесь появится отчёт выбранного задания.")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.frame(height: 180).background(Color(nsColor: .controlBackgroundColor))
            }
            Divider()
            HStack {
                Button { state.isLogVisible.toggle() } label: {
                    Label("Журнал", systemImage: state.isLogVisible ? "chevron.down" : "chevron.up")
                }
                Spacer()
                Button(role: .destructive, action: state.clearFinishedJobs) {
                    Label("Убрать завершённые", systemImage: "trash")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                .help("Убрать завершённые задания из списка. Файлы результатов сохраняются.")
            }.padding(16).background(.bar)
        }
    }
    private func icon(_ state: QueueJobState) -> String {
        switch state { case .waiting: "clock"; case .running: "arrow.triangle.2.circlepath"; case .finished: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .failed: "xmark.circle.fill"; case .cancelled: "minus.circle" }
    }
    private func color(_ state: QueueJobState) -> Color {
        switch state { case .finished: .green; case .warning: .orange; case .failed: .red; case .running: .blue; default: .secondary }
    }
}
