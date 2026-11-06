import NullViewCore
import SwiftUI

/// Settings section: list status, "Update now", custom rules, allowed sites.
struct BlockingSection: View {
    @ObservedObject var blocker: Blocker

    var body: some View {
        Section {
            ForEach(blocker.config.all, id: \.id) { l in
                Toggle(isOn: Binding(get: { blocker.config.isEnabled(l.id) },
                                     set: { on in Task { await blocker.setEnabled(l.id, on) } })) {
                    row(l.id, l.name)
                }
                .disabled(blocker.isUpdating)
                .deleteDisabled(!blocker.config.isCustom(l.id))
            }
            .onDelete { offsets in
                let all = blocker.config.all
                offsets.map { all[$0].id }.forEach { id in Task { await blocker.removeList(id) } }
            }
            NavigationLink("Add a list") { AddListView(blocker: blocker) }
            row(Blocker.customID, "Custom rules")
            if let e = blocker.errors["engine"] { Text(e).font(.footnote).foregroundStyle(.red) }
            Button { Task { await blocker.update() } } label: {
                HStack { Text("Update now"); if blocker.isUpdating { Spacer(); ProgressView() } }
            }
            .disabled(blocker.isUpdating)
            NavigationLink("Custom rules") { CustomRulesView(blocker: blocker) }
            NavigationLink("Allowed sites (\(blocker.allowlist.hosts.count))") { AllowlistView(blocker: blocker) }
        } header: { Text("Blocking") } footer: {
            Text("Lists update when older than 24 hours, at launch and when you come back to the app. Cookie Notices and Popups are off until you turn them on. Swipe a list you added to remove it. If an update fails, the last working lists keep blocking. Only the list downloads leave this device.")
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
                Text("One rule per line, AdBlock Plus or AdGuard syntax. Example: ||ads.example.com^ or example.com##.banner. To hide something without typing a rule, long-press the shield in the toolbar and choose Hide an element.")
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

struct AddListView: View {
    @ObservedObject var blocker: Blocker
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var message: String?
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $name)
                TextField("https://example.com/list.txt", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("A filter list in AdBlock Plus or AdGuard syntax. Only https addresses. It is downloaded now and kept up to date like the others.")
            }
            Section {
                Button { add() } label: {
                    HStack { Text("Add"); if adding { Spacer(); ProgressView() } }
                }
                .disabled(adding || url.trimmingCharacters(in: .whitespaces).isEmpty)
                if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add a list")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        adding = true
        Task {
            message = await blocker.addList(name: name, url: url)
            adding = false
            if message == nil { dismiss() }
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
