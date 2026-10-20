import SwiftUI

struct RootSplitView: View {
    @Bindable var state: AppState
    var body: some View {
        NavigationSplitView {
            SidebarView(state: state).navigationSplitViewColumnWidth(min: 205, ideal: 300, max: 300)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch state.selectedSection ?? .workspace {
                    case .workspace: DetailEditorView(state: state)
                    case .output: OutputOptionsView(state: state)
                    case .chapters: ChapterEditorView(state: state)
                    case .attachments: AttachmentsView(state: state)
                    case .information: InformationView(state: state)
                    case .queue: QueueView(state: state)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.selectedSection != .queue { OutputBar(state: state) }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .inspector(isPresented: $state.isInspectorVisible) {
                InspectorView(state: state).inspectorColumnWidth(min: 260, ideal: 380, max: 380)
            }
        }
        .onChange(of: state.project) { state.scheduleWorkspaceSave() }
        .preferredColorScheme(state.appearance == "light" ? .light : state.appearance == "dark" ? .dark : nil)
        .onChange(of: state.selectedTrackID) {
            if let source = state.trackSource { state.selectedFileID = source.id }
        }
        .navigationTitle("MKVStudio")
        .navigationSubtitle(state.selectedSection?.title ?? "Сборка")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: state.importFiles) { Label("Добавить файлы", systemImage: "plus") }.help("Добавить файлы · ⌘O").disabled(state.isImporting)
                Menu {
                    Button("Открыть проект…", action: state.openProject)
                    Button("Сохранить проект…", action: state.saveProject)
                    Divider()
                    Button("Выбрать инструменты…", action: state.chooseTools)
                } label: { Label("Проект", systemImage: "ellipsis.circle") }
                Button { state.isInspectorVisible.toggle() } label: { Label("Свойства", systemImage: "sidebar.trailing") }.help("Свойства · ⌥⌘I")
            }
        }
        .frame(minWidth: 1200, minHeight: 650)
        .alert("Не удалось выполнить операцию", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("Понятно", role: .cancel) { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            guard !state.isImporting else { return false }
            Task { await state.importURLs(urls) }; return true
        }
    }
}

struct OutputBar: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.doc").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.project.split.enabled ? "Папка с частями" : "Файл результата").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(state.project.outputPath.isEmpty ? "Выберите место сохранения" : MKVCommandBuilder.destination(state.project).lastPathComponent)
                            .font(.callout).lineLimit(1).truncationMode(.middle).help(MKVCommandBuilder.destination(state.project).path)
                        Spacer(minLength: 4)
                        Button("Выбрать…", action: state.chooseOutput).controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 22)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button { state.enqueue(start: false) } label: {
                    Label("Добавить в очередь", systemImage: "text.badge.plus")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                .help("Добавить в очередь").disabled(!state.canMux)
                Button { state.enqueue(start: true) } label: {
                    Text("Собрать MKV").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!state.canMux).keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 22).padding(.bottom, 16)
        }
        .background(.bar)
    }
}
