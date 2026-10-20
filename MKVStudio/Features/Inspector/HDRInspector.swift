import SwiftUI

struct HDRInspector: View {
    @Bindable var state: AppState
    let track: TrackRow
    var body: some View {
        Section("Цвет и HDR") {
            Menu("Заполнить цветовые параметры") {
                Button("BT.2020 + PQ") { preset(transfer: "16") }
                Button("BT.2020 + HLG") { preset(transfer: "18") }
                Divider()
                Button("Сохранить все исходные значения") { state.updateTrack(track.id) { $0.hdr = nil } }
            }
            ForEach([HDRField.transfer, .primaries, .matrix, .range], id: \.self) { field in
                Picker(field.title, selection: binding(field)) {
                    Text("Сохранить").tag("")
                    ForEach(field.choices, id: \.0) { Text($0.1).tag($0.0) }
                    if let current = track.hdr?[field.rawValue], !current.isEmpty, !field.choices.contains(where: { $0.0 == current }) { Text("Код \(current)").tag(current) }
                }
            }
            TextField(HDRField.bits.title, text: binding(.bits), prompt: Text("Сохранить"))
            DisclosureGroup("Яркость и мастеринг") {
                ForEach([HDRField.maxCLL, .maxFALL, .maxLuminance, .minLuminance], id: \.self) { field in
                    TextField(field.title, text: binding(field), prompt: Text("Сохранить"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Координаты R, G, B").font(.body)
                    TextField("Rx,Ry,Gx,Gy,Bx,By", text: binding(.chromaticity)).labelsHidden()
                    Text("Белая точка x, y").font(.body)
                    TextField("Например 0.3127,0.3290", text: binding(.white)).labelsHidden()
                }
            }
            Text("Пустое поле сохраняет исходное значение. Меняются только метаданные: это не преобразование SDR в HDR и не изменение глубины видеопотока.").font(.body).foregroundStyle(.secondary)
        }
    }
    private func binding(_ field: HDRField) -> Binding<String> {
        Binding(get: { state.tracks.first { $0.id == track.id }?.hdr?[field.rawValue] ?? "" }, set: { value in
            state.updateTrack(track.id) { if $0.hdr == nil { $0.hdr = [:] }; $0.hdr?[field.rawValue] = value }
        })
    }
    private func preset(transfer: String) {
        state.updateTrack(track.id) {
            var hdr = $0.hdr ?? [:]
            hdr[HDRField.primaries.rawValue] = "9"; hdr[HDRField.matrix.rawValue] = "9"; hdr[HDRField.transfer.rawValue] = transfer
            $0.hdr = hdr
        }
    }
}
