import SwiftUI

struct DetailEditorView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Соберите свою версию").font(.system(size: 25, weight: .semibold))
                    Text("Видео, звук и субтитры — в одном MKV.").foregroundStyle(.secondary)
                }
                Spacer()
                if state.isImporting { ProgressView().controlSize(.small).help(state.importLabel) }
            }.padding(24)
            if state.files.isEmpty {
                ContentUnavailableView {
                    Label("Добавьте исходные файлы", systemImage: "film.stack")
                } description: {
                    Text("Перетащите сюда видео, аудио или субтитры.\nКачество исходных дорожек сохраняется.")
                } actions: {
                    Button("Выбрать файлы…", action: state.importFiles).buttonStyle(.borderedProminent).disabled(state.isImporting)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("Дорожки").font(.headline)
                    Text("\(state.tracks.filter(\.included).count) из \(state.tracks.count)").foregroundStyle(.secondary)
                    Spacer()
                    Menu("Выбрать") {
                        Button("Все дорожки") { for track in state.tracks { state.updateTrack(track.id) { $0.included = true } } }
                        ForEach(TrackKind.allCases, id: \.self) { kind in
                            Button("Только \(kind.title.lowercased())") {
                                for track in state.tracks { state.updateTrack(track.id) { $0.included = $0.kind == kind } }
                            }
                        }
                    }.fixedSize()
                }.padding(.horizontal, 24).padding(.bottom, 12)
                Table(state.tracks, selection: $state.selectedTrackID) {
                    TableColumn("") { track in
                        Toggle("Включить \(track.kind.title)", isOn: Binding(get: { track.included }, set: { value in state.updateTrack(track.id) { $0.included = value } }))
                            .labelsHidden().toggleStyle(.checkbox)
                    }.width(26)
                    TableColumn("Дорожка") { track in
                        HStack(spacing: 10) {
                            Image(systemName: track.kind.symbol).foregroundStyle(track.kind == .video ? Color.blue : track.kind == .audio ? Color.green : Color.orange).frame(width: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.name.isEmpty ? track.kind.title : track.name).lineLimit(1)
                                Text(track.details.isEmpty ? track.kind.title : track.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 7).opacity(track.included ? 1 : 0.45)
                        .contextMenu {
                            Button("Выше") { state.moveTrack(track.id, offset: -1) }
                            Button("Ниже") { state.moveTrack(track.id, offset: 1) }
                        }
                    }.width(min: 145, ideal: 190)
                    TableColumn("Кодек") { Text($0.codec).font(.callout).lineLimit(1) }.width(min: 90, ideal: 110)
                    TableColumn("Язык") { Text($0.language.uppercased()).font(.caption.monospaced()) }.width(60)
                    TableColumn("Флаги") { track in
                        HStack(spacing: 8) {
                            if track.defaultTrack { Image(systemName: "star.fill").foregroundStyle(.orange).help("По умолчанию") }
                            if track.forced { Image(systemName: "flag.fill").foregroundStyle(.blue).help("Принудительно") }
                        }.font(.caption)
                    }.width(55)
                }
                .tableStyle(.inset)
                Divider()
                HStack {
                    Label("Исходные файлы сохраняются", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(state.files.count) файл(ов)").foregroundStyle(.secondary)
                }.font(.caption).padding(18)
            }
        }
    }
}
