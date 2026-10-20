// Separate QA executable only. The production app never uses synthetic API responses.
import SwiftUI

@main struct KinopoiskHarness: App {
    @StateObject private var owner = HarnessOwner()
    var body: some Scene {
        Window("MKVStudio · проверка поиска", id: "qa") { HarnessRoot(owner: owner) }
            .defaultSize(width: 1400, height: 860)
    }
}
@MainActor final class HarnessOwner: ObservableObject {
    let state = AppState(persistenceEnabled: false)
    var client: KinopoiskClient {
        KinopoiskClient(key: "fixture-only", transport: { request, _, poster in
            try await Task.sleep(for: .milliseconds(180))
            if poster { return HTTPPayload(status: 200, data: try Data(contentsOf: Bundle.main.url(forResource: "poster", withExtension: "png")!)) }
            let film = #"{"kinopoiskId":301,"nameRu":"Проверочный фильм","nameOriginal":"Sample","year":1999,"type":"FILM","description":"Описание для проверки переноса выбранных полей.","shortDescription":"Краткое содержание","posterUrl":"https://kinopoiskapiunofficial.tech/images/posters/kp/301.jpg","genres":[{"genre":"фантастика"}],"countries":[{"country":"США"}]}"#
            let staff = #"[{"nameRu":"Проверочный режиссёр","professionKey":"DIRECTOR"},{"nameRu":"Проверочный актёр","professionKey":"ACTOR"}]"#
            let json = request.url!.path == "/api/v2.2/films" ? "{\"totalPages\":1,\"items\":[\(film)]}" : request.url!.path == "/api/v1/staff" ? staff : film
            return HTTPPayload(status: 200, data: Data(json.utf8))
        })
    }
}
struct HarnessRoot: View {
    @ObservedObject var owner: HarnessOwner
    @StudioViewState private var context: KinopoiskSearchContext?
    var body: some View {
        RootSplitView(state: owner.state)
            .toolbar {
                Button("Поиск · тестовые ответы") {
                    if let file = owner.state.files.first {
                        context = KinopoiskSearchContext(id: file.id, generation: owner.state.metadataGeneration, query: "Проверочный фильм")
                    }
                }.disabled(owner.state.files.isEmpty)
            }
            .sheet(item: $context) { context in KinopoiskSearchView(state: owner.state, context: context, client: owner.client) }
            .task {
                await owner.state.detectTools()
                await owner.state.importURLs([URL(fileURLWithPath: "/tmp/MKVStudio-ui-050/source.mkv")])
                owner.state.selectedSection = .tags
            }
    }
}
