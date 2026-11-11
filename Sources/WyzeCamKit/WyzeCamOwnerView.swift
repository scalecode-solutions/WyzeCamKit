import SwiftUI

/// The owner screen: your cameras (each opens `WyzeCamProfileView`), cameras
/// shared with you, and your home boxes. Push it inside the host's navigation
/// stack; show its entry point only to owners
/// (`engine.cameras.contains(where: \.owned)`) unless the host lets a fresh
/// account add its first home box. `extra` appends the host's own sections.
public struct WyzeCamOwnerView<Extra: View>: View {
    let engine: WyzeCamEngine
    let allowsAddingHomeBoxes: Bool
    let extra: Extra

    public init(engine: WyzeCamEngine, allowsAddingHomeBoxes: Bool = true,
                @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.engine = engine
        self.allowsAddingHomeBoxes = allowsAddingHomeBoxes
        self.extra = extra()
    }

    @State private var agents: [WyzeCamAgent]?
    @State private var grants: [WyzeCamGrant] = []
    @State private var adding = false
    @State private var message: String?

    private var owned: [WyzeCamera] { engine.cameras.filter(\.owned) }
    private var shared: [WyzeCamera] { engine.cameras.filter { !$0.owned } }

    public var body: some View {
        Form {
            Section {
                if owned.isEmpty {
                    Text("Cameras appear here once a home box you added reports them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(owned) { cam in
                    NavigationLink {
                        WyzeCamProfileView(engine: engine, cameraID: cam.id)
                    } label: {
                        cameraRow(cam)
                    }
                }
            } header: {
                Text("Your cameras")
            }

            if !shared.isEmpty {
                Section {
                    ForEach(shared) { cam in cameraRow(cam, sharedWithMe: true) }
                } header: {
                    Text("Shared with you")
                } footer: {
                    Text("Their owners decide who can watch them.")
                }
            }

            Section {
                if let agents {
                    ForEach(agents) { a in
                        NavigationLink {
                            WyzeCamAgentView(engine: engine, agent: a)
                        } label: {
                            agentRow(a)
                        }
                    }
                    if agents.isEmpty {
                        Text("No home boxes yet.").foregroundStyle(.secondary)
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if allowsAddingHomeBoxes {
                    Button { adding = true } label: {
                        Label("Add a home box", systemImage: "plus")
                    }
                }
            } header: {
                Text("Home boxes")
            } footer: {
                Text("A home box is the computer at home that reaches your cameras and streams them only while someone watches.")
            }

            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            extra
        }
        .navigationTitle("Cameras")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable {
            await engine.refresh()
            await load()
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            WyzeCamAddAgentSheet(engine: engine)
        }
    }

    private func cameraRow(_ cam: WyzeCamera, sharedWithMe: Bool = false) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(CameraTint(color: cam.color))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(cam.name)
                Text(subtitle(cam, sharedWithMe: sharedWithMe))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(cam.online ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .accessibilityLabel(cam.online ? "Online" : "Offline")
        }
    }

    private func subtitle(_ cam: WyzeCamera, sharedWithMe: Bool) -> String {
        if sharedWithMe { return cam.online ? "Online" : "Offline" }
        let n = grants.filter { $0.cameraID == cam.id && WyzeCamSharing.isActive($0) }.count
        let who = n == 0 ? "Only you" : n == 1 ? "Shared with 1 person" : "Shared with \(n) people"
        return (cam.online ? "Online" : "Offline") + " · " + who
    }

    private func agentRow(_ a: WyzeCamAgent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(a.online ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name)
                Text(WyzeCamSharing.agentLine(a))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            async let a = engine.agents()
            async let g = engine.grants(for: nil)
            agents = try await a
            grants = try await g
            message = nil
        } catch {
            if agents == nil { agents = [] }
            message = WyzeCamEngine.describe(error)
        }
    }
}

// MARK: - One camera

/// One camera's profile, for its owner: name, color, who can watch it, and
/// what it is. Pushed from `WyzeCamOwnerView` or the live view.
public struct WyzeCamProfileView: View {
    let engine: WyzeCamEngine
    let cameraID: UUID

    public init(engine: WyzeCamEngine, cameraID: UUID) {
        self.engine = engine
        self.cameraID = cameraID
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    /// The server's name when the field was last filled from it: a rename
    /// from elsewhere replaces the field only if it hasn't been edited.
    @State private var syncedName = ""
    @State private var grants: [WyzeCamGrant]?
    @State private var contacts: [WyzeCamContact] = []
    @State private var sharing = false
    @State private var removing: WyzeCamGrant?
    @State private var message: String?
    @State private var saved = 0

    private var camera: WyzeCamera? { engine.camera(cameraID) }
    private var owner: UUID { engine.config.currentUserID }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        Group {
            if let camera {
                form(camera)
            } else {
                ContentUnavailableView("Camera removed", systemImage: "video.slash")
            }
        }
        .navigationTitle(camera?.name ?? "Camera")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: saved)
    }

    private func form(_ cam: WyzeCamera) -> some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(cam.online ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(cam.online ? "Online" : "Offline")
                    TextField("Camera name", text: $name)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveName(cam) } }
                    if trimmedName != cam.name && !trimmedName.isEmpty {
                        Button("Save") { Task { await saveName(cam) } }
                            .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text(cam.online ? "Online now." : "Its home box can't reach it right now.")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                    ForEach(WyzeCamColor.palette, id: \.self) { c in
                        let selected = cam.color == c || (cam.color == .standard && c == .cyan)
                        Button {
                            Task { await save(cam, color: c) }
                        } label: {
                            Circle()
                                .fill(c.color(dark: colorScheme == .dark))
                                .frame(height: 36)
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.footnote.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.label)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Color")
            }

            sharingSection(cam)

            Section {
                LabeledContent("Key", value: cam.camKey)
                LabeledContent("Picture", value: cam.hasSD ? "HD + SD" : "HD")
            } header: {
                Text("Camera")
            } footer: {
                Text("The key is this camera's name in its home box's config.")
            }

            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { name = cam.name; syncedName = cam.name }
        .onChange(of: cam.name) { _, newName in
            name = WyzeCamSharing.followRename(field: name, lastSynced: syncedName, server: newName)
            syncedName = newName
        }
        .task(id: cam.id) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $sharing) {
            WyzeCamShareSheet(
                cameraName: cam.name,
                candidates: WyzeCamSharing.candidates(contacts: contacts, grants: grants ?? [], owner: owner)
            ) { contact, until in
                _ = try await engine.share(cam.id, with: contact, until: until)
                await load()
            }
        }
        .confirmationDialog(
            removing.map { "Stop sharing with \(WyzeCamSharing.displayName(for: $0, contacts: contacts))?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { grant in
            Button("Stop sharing", role: .destructive) { Task { await remove(grant) } }
        } message: { _ in
            Text("If they're watching, it stops right away. You can share again later.")
        }
    }

    private func sharingSection(_ cam: WyzeCamera) -> some View {
        Section {
            if let list = grants {
                if list.isEmpty {
                    Text("Only you can watch this camera.").foregroundStyle(.secondary)
                }
                ForEach(list) { grant in
                    personRow(grant)
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = grant }
                        }
                        .contextMenu {
                            Button("Stop sharing", systemImage: "person.badge.minus", role: .destructive) {
                                removing = grant
                            }
                        }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            Button { sharing = true } label: {
                Label("Share…", systemImage: "person.badge.plus")
            }
        } header: {
            Text("Who can watch")
        } footer: {
            if !(grants ?? []).isEmpty {
                Text("Swipe a person to stop sharing with them.")
            }
        }
    }

    private func personRow(_ grant: WyzeCamGrant) -> some View {
        let name = WyzeCamSharing.displayName(for: grant, contacts: contacts)
        let avatar = contacts.first { $0.id == grant.granteeID }?.avatar
        return HStack(spacing: 12) {
            WyzeCamAvatar(name: name, data: avatar)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(WyzeCamSharing.accessLine(grant))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            async let g = engine.grants(for: cameraID)
            async let c = engine.contacts()
            grants = try await g
            contacts = (try? await c) ?? contacts
            message = nil
        } catch {
            if grants == nil { grants = [] }
            message = WyzeCamEngine.describe(error)
        }
    }

    private func saveName(_ cam: WyzeCamera) async {
        guard !trimmedName.isEmpty, trimmedName != cam.name else { return }
        do {
            try await engine.rename(cam, to: trimmedName)
            syncedName = trimmedName
            name = trimmedName
            saved += 1
            message = nil
        } catch {
            message = "Couldn't rename: \(WyzeCamEngine.describe(error))"
        }
    }

    private func save(_ cam: WyzeCamera, color: WyzeCamColor) async {
        do {
            try await engine.setColor(color, of: cam)
            saved += 1
        } catch {
            message = "Couldn't change the color: \(WyzeCamEngine.describe(error))"
        }
    }

    private func remove(_ grant: WyzeCamGrant) async {
        do {
            try await engine.revoke(grant)
            await load()
        } catch {
            message = "Couldn't stop sharing: \(WyzeCamEngine.describe(error))"
        }
    }
}

// MARK: - Share sheet

struct WyzeCamShareSheet: View {
    let cameraName: String
    let candidates: [WyzeCamContact]
    let share: (WyzeCamContact, Date?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: WyzeCamContact.ID?
    @State private var hasEnd = false
    @State private var end = Date.now.addingTimeInterval(24 * 3600)
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?

    private var shown: [WyzeCamContact] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? candidates : candidates.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if candidates.isEmpty {
                        Text("No one else to add. People appear here once you're connected with them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown) { c in
                        Button { selection = c.id } label: {
                            HStack(spacing: 12) {
                                WyzeCamAvatar(name: c.name, data: c.avatar)
                                Text(c.name).foregroundStyle(.primary)
                                Spacer()
                                if selection == c.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Share with")
                }

                Section {
                    Toggle("End date", isOn: $hasEnd.animation())
                    if hasEnd {
                        DatePicker("Until", selection: $end, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    }
                } footer: {
                    Text(hasEnd ? "Access ends on its own at that time." : "Access lasts until you remove it.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Share \(cameraName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") { Task { await submit() } }
                        .disabled(selection == nil || busy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        guard let c = candidates.first(where: { $0.id == selection }) else { return }
        busy = true
        defer { busy = false }
        do {
            try await share(c, hasEnd ? end : nil)
            dismiss()
        } catch {
            self.error = "Couldn't share with \(c.name). They may not be able to see you yet."
        }
    }
}

// MARK: - Home boxes

/// One home box: its state, and a new token when the old one leaked or the
/// box is being rebuilt.
struct WyzeCamAgentView: View {
    let engine: WyzeCamEngine
    let agent: WyzeCamAgent

    @State private var confirming = false
    @State private var rotating = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: WyzeCamSharing.agentLine(agent))
                if !agent.version.isEmpty { LabeledContent("Version", value: agent.version) }
                if let created = agent.createdAt {
                    LabeledContent("Added", value: created.formatted(date: .abbreviated, time: .omitted))
                }
                let cams = engine.cameras.filter { $0.agentID == agent.id }
                LabeledContent("Cameras", value: "\(cams.count)")
            }

            Section {
                Button("New token…", role: .destructive) { confirming = true }
            } header: {
                Text("Token")
            } footer: {
                Text("The home box signs in with its token. A new one stops the old one at once; the box goes offline until its config has the new one.")
            }
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Make a new token for \(agent.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("New token", role: .destructive) { rotating = true }
        } message: {
            Text("The current token stops working right away.")
        }
        // The new token lives in a sheet that makes the request itself and
        // can't be swiped away: once the old token is dead, losing the new
        // one to a back-swipe would strand the home box.
        .sheet(isPresented: $rotating) {
            WyzeCamTokenSheet(title: "New token for \(agent.name)") {
                try await engine.rotateToken(of: agent)
            }
        }
    }
}

/// Fetches a token once and shows it until Done. Can't be dismissed while the
/// request is in flight or before the token has been seen.
struct WyzeCamTokenSheet: View {
    let title: String
    let fetch: () async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var token: String?
    @State private var error: String?
    @State private var started = false

    var body: some View {
        NavigationStack {
            Form {
                if let token {
                    Section {
                        TokenBox(token: token)
                    } footer: {
                        Text("Shown once. Put it in the home box's config as \"token\", then restart it.")
                    }
                } else if let error {
                    Section { Text(error).foregroundStyle(.red) }
                } else {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(token == nil && error == nil)
                }
            }
        }
        .interactiveDismissDisabled(!WyzeCamSharing.tokenSheetSwipeable(token: token, failed: error != nil))
        .task {
            guard !started else { return }
            started = true
            do {
                token = try await fetch()
            } catch {
                self.error = "Couldn't make a new token: \(WyzeCamEngine.describe(error)). The old one still works."
            }
        }
    }
}

/// Register a new home box. The token is shown once.
struct WyzeCamAddAgentSheet: View {
    let engine: WyzeCamEngine

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var result: RegisteredAgent?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    Section {
                        TokenBox(token: result.token)
                    } header: {
                        Text("\(result.agent.name)'s token")
                    } footer: {
                        Text("Shown once. Put it in the home box's config as \"token\". Its cameras appear here once it connects.")
                    }
                } else {
                    Section {
                        TextField("Name (e.g. Garage PC)", text: $name)
                            .submitLabel(.done)
                            .disabled(busy)
                            .onSubmit { Task { await add() } }
                    } footer: {
                        Text("The computer at home that reaches your cameras.")
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Add a home box")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        // Not while registering: the box would exist with a token nobody saw.
                        Button("Cancel", role: .cancel) { dismiss() }
                            .disabled(busy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if busy {
                            ProgressView()
                        } else {
                            Button("Add") { Task { await add() } }
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(result != nil || busy) // don't lose the token to a swipe
    }

    private func add() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !busy, result == nil else { return } // one registration per sheet
        busy = true
        defer { busy = false }
        do {
            result = try await engine.registerAgent(name: n)
        } catch {
            self.error = "Couldn't add it: \(WyzeCamEngine.describe(error))"
        }
    }
}

/// A token, selectable, with a copy button.
private struct TokenBox: View {
    let token: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(token)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = token
                copied = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Avatar

struct WyzeCamAvatar: View {
    let name: String
    let data: Data?
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.tint.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}
