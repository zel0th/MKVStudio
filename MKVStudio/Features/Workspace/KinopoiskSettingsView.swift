import SwiftUI

// Select the back-deployable wrapper explicitly: CLT lacks the SDK 27 State macro plugin.
typealias StudioViewState<Value> = SwiftUI.State<Value>

struct KinopoiskSettingsView: View {
    @StudioViewState private var draft = ""
    @StudioViewState private var stored = false
    @StudioViewState private var status = ""
    @StudioViewState private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Информация о фильмах").font(.title2.weight(.semibold))
            GroupBox("Kinopoisk Unofficial API") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Поиск названий, описаний, участников съёмочной группы и постеров. Это независимый сервис доступа к данным Кинопоиска.")
                    SecureField(stored ? "Новый ключ API (текущий сохранён)" : "Ключ API", text: $draft).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Ключ Kinopoisk Unofficial API")
                    HStack {
                        Button("Сохранить ключ") {
                            perform { try APIKeyStore().save(draft); draft = ""; stored = true; status = "Ключ сохранён в Связке ключей macOS." }
                        }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Удалить ключ", role: .destructive) {
                            perform { try APIKeyStore().delete(); draft = ""; stored = false; status = "Ключ удалён." }
                        }.disabled(!stored)
                    }
                    Label(status.isEmpty ? (stored ? "Ключ сохранён" : "Ключ пока не задан") : status,
                          systemImage: failed ? "exclamationmark.triangle" : "key")
                        .foregroundStyle(failed ? Color.red : Color.secondary)
                    Text("Ключ не попадает в проекты, журналы и репозиторий. Поиск запускается вручную в редакторе тегов; сервис получает только введённый запрос. Видео и аудио не отправляются.")
                        .foregroundStyle(.secondary)
                    Link("Регистрация и получение ключа", destination: URL(string: "https://kinopoiskapiunofficial.tech/")!)
                    Link("Документация и лимиты сервиса", destination: URL(string: "https://kinopoiskapiunofficial.tech/documentation/api/")!)
                }.padding(14)
            }
            Spacer(minLength: 0)
        }.padding(20)
        .onAppear { perform { stored = try APIKeyStore().read() != nil } }
        .onDisappear { draft = "" }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); failed = false } catch { status = error.localizedDescription; failed = true }
    }
}
