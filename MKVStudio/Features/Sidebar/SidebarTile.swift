import SwiftUI

struct StatusDot: View {
    var available: Bool
    var body: some View {
        Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(available ? Color.green : Color.orange)
            .accessibilityLabel(available ? "Инструменты доступны" : "Инструменты не найдены")
    }
}
