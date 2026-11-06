import NullViewCore
import SwiftUI

/// Settings section: list status, "Update now", custom rules, allowed sites.
struct BlockingSection: View {
    @ObservedObject var blocker: Blocker

    var body: some View {
        Section {
            ForEach(Filters.defaults, id: \.id) { row($0.id, $0.name) }
            row(Blocker.customID, "Custom rules")
            if let e = blocker.errors["engine"] { Text(e).font(.footnote).foregroundStyle(.red) }
            Button { Task { await blocker.update() } } label: {
                HStack { Text("Update now"); if blocker.isUpdating { Spacer(); ProgressView() } }
            }
            .disabled(blocker.isUpdating)
            NavigationLink("Custom rules") { CustomRulesView(blocker: blocker) }
            NavigationLink("Allowed sites (\(blocker.allowlist.hosts.count))") { AllowlistView(blocker: blocker) }
        } header: { Text("Blocking") } footer: {
            Text("Lists update at launch when older than 24 hours. If an update fails, the last working lists keep blocking. Only the list downloads leave this device.")
        }
    }

    private func row(_ id: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            if let m = blocker.meta[id] {
                Text("\(m.safariRules.formatted()) rules, updated \(m.updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if id != Blocker.customID {
                Text("Not downloaded yet").font(.footnote).foregroundStyle(.secondary)
            }
            if let e = blocker.errors[id] {
                Text("Update failed: \(e)").font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

struct CustomRulesView: View {
    @ObservedObject var blocker: Blocker
    @State private var text = ""
    @State private var message: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 220)
            } footer: {
                Text("One rule per line, AdBlock Plus or AdGuard syntax. Example: ||ads.example.com^ or example.com##.banner")
            }
            Section {
                Button { save() } label: {
                    HStack { Text("Save and apply"); if saving { Spacer(); ProgressView() } }
                }
                .disabled(saving)
                if let m = blocker.meta[Blocker.customID] {
                    Text("\(m.safariRules) rules compiled, \(m.invalidRules) invalid").font(.footnote)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Custom rules")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = blocker.customRules }
    }

    private func save() {
        saving = true
        Task {
            message = await blocker.saveCustomRules(text)
            saving = false
        }
    }
}

struct AllowlistView: View {
    @ObservedObject var blocker: Blocker
    @State private var newHost = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("example.com", text: $newHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(AllowList.normalize(newHost) == nil)
                }
            } footer: {
                Text("Blocking is off for these sites and their subdomains. The shield button in the toolbar adds the current site.")
            }
            Section {
                ForEach(blocker.allowlist.hosts, id: \.self) { Text($0) }
                    .onDelete { offsets in
                        let hosts = blocker.allowlist.hosts
                        offsets.forEach { blocker.removeAllowed(hosts[$0]) }
                    }
            }
        }
        .navigationTitle("Allowed sites")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        blocker.addAllowed(newHost)
        newHost = ""
    }
}
