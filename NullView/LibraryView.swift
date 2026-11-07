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
    @State private var all: [Item] = []
    @State private var search = ""
    @State private var sort = LibrarySort.newest
    @State private var site: String?
    @State private var confirmClear = false

    /// `all` after search, site filter and sort. The queue keeps its own order (it is the play order).
    private var items: [Item] {
        LibraryQuery.apply(all, search: search, site: site, sort: tab == .queue ? .newest : sort) { ($0.title, $0.page) }
    }
    private var sites: [String] { Set(all.map { LibraryQuery.host($0.page) }).sorted() }
    private var canClear: Bool { tab == .history || tab == .queue }

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
                    if items.isEmpty {
                        Text(all.isEmpty ? "Nothing here yet." : "No matches.").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        Button { open(item) } label: { row(item) }
                    }
                    .onDelete(perform: delete)
                    // Reordering is only safe when the list on screen is the whole queue.
                    .onMove(perform: tab == .queue && search.isEmpty && site == nil ? moveInQueue : nil)
                } footer: {
                    if canClear && !all.isEmpty {
                        Button(tab == .history ? "Clear history" : "Clear queue", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search saved videos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { filterMenu }
                if tab == .queue { ToolbarItem(placement: .secondaryAction) { EditButton() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(tab == .history ? "Clear all history?" : "Clear the queue?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button(tab == .history ? "Clear history" : "Clear queue", role: .destructive) {
                    if tab == .history { library.store.clearHistory() } else { library.store.setQueue([]) }
                    reload()
                }
            }
            .onAppear(perform: reload)
            .onChange(of: tab) { _, _ in site = nil; reload() }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .disabled(tab == .queue)
            Picker("Site", selection: $site) {
                Text("All sites").tag(String?.none)
                ForEach(sites, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        } label: {
            Image(systemName: sort == .newest && site == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Sort and filter")
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.poster.flatMap(URL.init(string:))) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2).overlay(Image(systemName: "play.rectangle").foregroundStyle(.secondary).accessibilityHidden(true))
            }
            .frame(width: 80, height: 45).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2).foregroundStyle(.primary)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p = item.progress { ProgressView(value: p).padding(.top, 2).accessibilityLabel("Watched").accessibilityValue("\(Int(p * 100)) percent") }
            }
        }
    }

    private func reload() {
        let now = Date()
        let host = LibraryQuery.host
        func ago(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }
        switch tab {
        case .continueWatching:
            all = library.continueWatching(now: now).map {
                Item(id: "\($0.id.page)#\($0.id.index)", page: $0.id.page, title: $0.title.isEmpty ? host($0.id.page) : $0.title,
                     poster: $0.poster, detail: "\(host($0.id.page)) · \(VideoGestures.clock($0.position)) of \(VideoGestures.clock($0.duration))",
                     progress: $0.duration > 0 ? $0.position / $0.duration : nil, index: $0.id.index)
            }
        case .later:
            all = library.store.watchLater().map { saved($0, detail: "saved \(ago($0.date))") }
        case .history:
            all = library.store.history().map { saved($0, detail: "\(host($0.page)) · \(ago($0.date))") }
        case .queue:
            all = library.store.queue().map {
                // No title (queued before titles existed, or the page gave none): host and path say more than the host alone.
                let u = URL(string: $0.page)
                let fallback = host($0.page) + (u?.path == "/" ? "" : u?.path ?? "")
                return Item(id: $0.page, page: $0.page, title: $0.title.isEmpty ? fallback : $0.title, poster: nil,
                            detail: host($0.page), progress: nil)
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

    private func moveInQueue(_ from: IndexSet, _ to: Int) {
        var q = library.store.queue()
        q.move(fromOffsets: from, toOffset: to)
        library.store.setQueue(q)
        reload()
    }
}
