import NullViewCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var blocker: Blocker
    let detector: VideoDetector
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BrowserModel.searchTemplateKey) private var template = AddressInput.defaultSearchTemplate
    @AppStorage(BrowserModel.desktopSiteKey) private var desktopSite = false
    @State private var confirmClear = false
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                BlockingSection(blocker: blocker)
                Section {
                    TextField("Search URL", text: $template)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !AddressInput.isValidSearchTemplate(template) {
                        Text("Needs %s where the query goes and must be an http(s) address. The default is used until this is fixed.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    Button("Reset to DuckDuckGo") { template = AddressInput.defaultSearchTemplate }
                } header: { Text("Search") } footer: {
                    Text("Text that is not a web address opens this URL, with %s replaced by what you typed.")
                }
                Section {
                    Toggle("Request desktop site", isOn: $desktopSite)
                } footer: {
                    Text("Loads pages as on a computer. Applies to the next page load.")
                }
                Section {
                    Text("nullview://open?url=")
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                } header: { Text("Sharing") } footer: {
                    Text("In the Shortcuts app, make a shortcut that accepts URLs from the share sheet and runs Open URLs on nullview://open?url= followed by the shared link. Copying a link also works: Null View offers to open it.")
                }
                Section {
                    Text(detector.logText.isEmpty ? "Nothing detected yet." : detector.logText)
                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    Button("Copy log") { UIPasteboard.general.string = detector.log.joined(separator: "\n") }
                } header: { Text("Video detection log") }
                Section {
                    Button("Clear website data", role: .destructive) { confirmClear = true }
                    if cleared { Text("Cookies, logins and site storage cleared.").font(.footnote) }
                } header: { Text("Privacy") } footer: {
                    Text("Nothing leaves this device except the pages you open.")
                }
            }
            .onChange(of: desktopSite) { model.reload() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear all cookies, logins and site storage?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { Task { await model.clearWebsiteData(); cleared = true } }
            }
        }
    }
}
