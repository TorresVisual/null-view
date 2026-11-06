import NullViewCore
import SwiftUI

/// Library sheet (decisions.md "App layout"): Continue Watching, Watch Later, History, Queue.
struct LibraryView: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable { case continueWatching = "Continue", later = "Later", history = "History", queue = "Queue" }

    private struct Item: Identifiable {
        let id: String
        let page: String
        let title: String
        let poster: String?
        let detail: String
        let progress: Double?
        var index = 0   // video index (Continue Watching only)
    }

    @State private var tab = Tab.continueWatching
    @State private var items: [Item] = []

    private var library: Library { model.watch.library }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("List", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                if let u = model.url, AddressInput.webURL(u.absoluteString) != nil {
                    Section("This page") {
                        Button(library.isLater(u) ? "Remove from Watch Later" : "Add to Watch Later") {
                            library.toggleLater(u, title: model.webView.title ?? "")
                            reload()
                        }
                        Button("Add to queue") { library.enqueue(u); reload() }
                    }
                }
                Section {
                    if items.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary) }
                    ForEach(items) { item in
                        Button { open(item) } label: { row(item) }
                    }
                    .onDelete(perform: delete)
                } footer: {
                    if tab == .history { Button("Clear history", role: .destructive) { library.store.clearHistory(); reload() } }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: reload)
            .onChange(of: tab) { _, _ in reload() }
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.poster.flatMap(URL.init(string:))) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2).overlay(Image(systemName: "play.rectangle").foregroundStyle(.secondary))
            }
            .frame(width: 80, height: 45).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2).foregroundStyle(.primary)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p = item.progress { ProgressView(value: p).padding(.top, 2) }
            }
        }
    }

    private func reload() {
        let now = Date()
        func host(_ page: String) -> String { URL(string: page)?.host ?? page }
        func ago(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }
        switch tab {
        case .continueWatching:
            items = library.continueWatching(now: now).map {
                Item(id: "\($0.id.page)#\($0.id.index)", page: $0.id.page, title: $0.title.isEmpty ? host($0.id.page) : $0.title,
                     poster: $0.poster, detail: "\(host($0.id.page)) · \(VideoGestures.clock($0.position)) of \(VideoGestures.clock($0.duration))",
                     progress: $0.duration > 0 ? $0.position / $0.duration : nil, index: $0.id.index)
            }
        case .later:
            items = library.store.watchLater().map { saved($0, detail: "saved \(ago($0.date))") }
        case .history:
            items = library.store.history().map { saved($0, detail: "\(host($0.page)) · \(ago($0.date))") }
        case .queue:
            items = library.store.queue().map {
                Item(id: $0, page: $0, title: host($0), poster: nil, detail: $0, progress: nil)
            }
        }
    }

    private func saved(_ s: SavedPage, detail: String) -> Item {
        Item(id: s.page, page: s.page, title: s.title.isEmpty ? (URL(string: s.page)?.host ?? s.page) : s.title,
             poster: s.poster, detail: detail, progress: nil)
    }

    private func open(_ item: Item) {
        guard let u = AddressInput.webURL(item.page) else { return }
        dismiss()
        model.load(u)
        // Things the user picked to watch go straight into video mode; history is just a page.
        if tab != .history { model.watch.enterVideoWhenReady(afterLoad: true) }
        if tab == .queue { library.removeFromQueue(page: item.page) }
    }

    private func delete(_ at: IndexSet) {
        for i in at {
            let p = items[i].page
            switch tab {
            case .continueWatching:
                library.store.deleteRecord(VideoID(page: p, index: items[i].index))
            case .later: library.store.deleteLater(page: p)
            case .history: library.store.deleteHistory(page: p)
            case .queue: library.removeFromQueue(page: p)
            }
        }
        reload()
    }
}
