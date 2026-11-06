import NullViewCore
import SwiftUI

/// Saved-sites launcher (issue #12): tiles for platforms the user added by hand, most opened first.
/// Used inline on the start page and inside `SitesSheet`.
struct SitesGrid: View {
    let model: BrowserModel
    var onOpen: () -> Void = {}

    @State private var list: [SavedSite] = []
    @State private var adding = false
    @State private var newAddress = ""
    @State private var newName = ""
    @State private var rejected = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(list, id: \.url) { site in
                    Button { open(site) } label: { tile(site) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { model.sites.remove(site); reload() }
                        }
                }
                Button { newAddress = ""; newName = ""; adding = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.title2).frame(width: 56, height: 56)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        Text("Add site").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .onAppear(perform: reload)
        .alert("Add site", isPresented: $adding) {
            TextField("Address, e.g. youtube.com", text: $newAddress)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Name (optional)", text: $newName)
            Button("Add") {
                if model.sites.add(newAddress, name: newName) == nil { rejected = true }
                reload()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Can't add that", isPresented: $rejected) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter a web address that isn't already saved.")
        }
    }

    private func tile(_ site: SavedSite) -> some View {
        VStack(spacing: 6) {
            Text(site.name.first.map { String($0).uppercased() } ?? "?")
                .font(.title2.weight(.semibold)).frame(width: 56, height: 56)
                .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            Text(site.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func open(_ site: SavedSite) {
        guard let u = AddressInput.webURL(site.url) else { return }
        model.sites.recordOpen(site)
        onOpen()
        model.load(u)
    }

    private func reload() { list = model.sites.ordered() }
}

/// The same grid as a sheet, for the toolbar.
struct SitesSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SitesGrid(model: model, onOpen: { dismiss() })
                .navigationTitle("Sites")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
