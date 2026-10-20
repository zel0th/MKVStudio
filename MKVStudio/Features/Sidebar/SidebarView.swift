import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState
    var body: some View {
        List(selection: $state.selectedSection) {
            Section("Рабочее пространство") {
                ForEach(StudioSection.allCases) { section in
                    Label {
                        HStack {
                            Text(section.title)
                            Spacer()
                            if section == .queue, state.waitingCount > 0 { Text("\(state.waitingCount)").foregroundStyle(.secondary) }
                        }
                    } icon: { Image(systemName: section.symbol).foregroundStyle(.blue) }
                    .tag(section)
                    .padding(.vertical, 3)
                }
            }
            Section {
                ForEach(state.files) { file in
                    Button {
                        state.selectedFileID = file.id
                        state.selectedTrackID = file.tracks.first?.id
                        state.selectedSection = .workspace
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "doc.zipper").foregroundStyle(.secondary).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.fileName).lineLimit(2).font(.callout)
                                Text("\(file.fileSize) · \(file.tracks.count) дор.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Показать в Finder") { state.reveal(file.url) }
                        Button("Убрать из сборки") { state.removeFile(file.id) }
                    }
                    .help(file.url.path)
                }
                if state.files.isEmpty {
                    Text("Файлы появятся здесь").font(.caption).foregroundStyle(.tertiary)
                }
            } header: {
                HStack { Text("Исходные файлы"); Spacer(); Text("\(state.files.count)") }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    StatusDot(available: state.tools != nil)
                    Text(state.tools == nil ? "Нужны консольные утилиты" : "Консольные утилиты готовы").font(.caption)
                }
                Text("Без перекодирования").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}
