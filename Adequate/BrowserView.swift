import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var spaces: SpaceStore

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { spaces.sidebarShown ? .all : .detailOnly },
            set: { spaces.sidebarShown = $0 != .detailOnly }
        )) {
            Sidebar(spaces: spaces, state: spaces.current)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            SpaceDetail(state: spaces.current)
                .id(spaces.selected)
        }
        // No title bar or toolbar: ⌘S shows and hides the sidebar.
        .toolbar(.hidden, for: .windowToolbar)
        .overlay(alignment: .bottom) {
            if let toast = spaces.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: spaces.toast)
        .overlay(alignment: .top) {
            // With the sidebar hidden, the site sits at the top of the window instead.
            if !spaces.sidebarShown { SiteBadge(state: spaces.current) }
        }
        .overlay { TabSwitcher(state: spaces.current) }
        .sheet(item: $spaces.prompt) { prompt in
            SpacePromptSheet(spaces: spaces, prompt: prompt)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var spaces: SpaceStore
    @ObservedObject var state: SpaceState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.space.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.space.name).font(.headline).lineLimit(1)
                    // Where you are, somewhere a page can't draw over.
                    if let tab = state.activeTab { SiteLabel(tab: tab) }
                }
                Spacer()
                Menu {
                    SpaceMenuItems(spaces: spaces, id: state.space.id)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 14)

            List(selection: Binding(get: { state.selectedTabID }, set: { state.choose($0) })) {
                // Pins first, kept across restarts, then a line, then the rest.
                ForEach(state.pinnedTabs) { row($0) }
                if !state.pinnedTabs.isEmpty && !state.unpinnedTabs.isEmpty {
                    Divider()
                }
                ForEach(state.unpinnedTabs) { row($0) }
            }

            DownloadsList(downloads: .shared)
            Divider()
            SpaceSwitcher(spaces: spaces)
        }
        // A wash of the Space's colour, so you can tell at a glance where you are.
        .background(state.space.tint.opacity(0.12))
        .tint(state.space.tint)
    }

    private func row(_ tab: Tab) -> some View {
                    TabRow(tab: tab,
                           inSplit: state.splitTabID == tab.id,
                           canSplit: state.selectedTabID != tab.id,
                           close: { state.close(tab.id) },
                           popOut: { spaces.openInNewWindow(tab.id, from: state) },
                           openSplit: { state.openSplit(with: tab.id) },
                           closeSplit: state.closeSplit,
                           dropTab: { items in
                               // Another tab dragged onto this one: show the two side by side.
                               guard let text = items.first, let dragged = UUID(uuidString: text) else { return false }
                               state.split(dragged, onto: tab.id)
                               return true
                           },
                           canPin: !state.space.isThrowaway,
                           togglePin: { tab.isPinned ? state.unpin(tab.id) : state.pin(tab.id) },
                           repin: { state.repin(tab.id) },
                           resetPermissions: { site in
                               state.resetPermissions(for: site)
                               spaces.show(toast: "\(site) can ask again")
                           })
                        .tag(tab.id)
    }
}

/// Edit, reorder and delete, shared by the header menu and each switcher dot.
struct SpaceMenuItems: View {
    @ObservedObject var spaces: SpaceStore
    let id: Space.ID

    var body: some View {
        let index = spaces.states.firstIndex { $0.space.id == id } ?? 0
        Button("Edit Space…") { spaces.prompt = .edit(id) }
        Button("Move Left") { spaces.move(id, by: -1) }.disabled(index == 0)
        Button("Move Right") { spaces.move(id, by: 1) }.disabled(index == spaces.states.count - 1)
        if spaces.state(id)?.space.isThrowaway == true {
            Divider()
            Button("Forget Everything") { spaces.forgetEverything(in: id) }
        }
        Divider()
        Button("Delete Space…", role: .destructive) { spaces.prompt = .delete(id) }
            .disabled(spaces.states.count < 2)
        Divider()
        Button("New Space…") { spaces.prompt = .new }
    }
}

/// One dot per Space along the bottom of the sidebar, like Arc's.
/// This run's downloads, at the foot of the sidebar while there are any.
struct DownloadsList: View {
    @ObservedObject var downloads: Downloads
    /// Beyond this many, only the newest show: the rest are in the folder.
    private let shown = 4

    var body: some View {
        if !downloads.items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Divider()
                HStack {
                    Text("Downloads").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", action: downloads.clear)
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(downloads.items.allSatisfy { $0.state == .running })
                    Button(action: downloads.showFolder) { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Show Downloads in Finder (⌥⌘L)")
                }
                .padding(.top, 6)
                ForEach(downloads.items.prefix(shown)) { DownloadRow(item: $0) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: Download
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let file = item.file, item.state == .finished {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable()
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.state == .finished ? .primary : .secondary)
                switch item.state {
                case .running:
                    ProgressView(value: item.fraction ?? 0).progressViewStyle(.linear).controlSize(.mini)
                        .opacity(item.fraction == nil ? 0.4 : 1)
                case .failed(let reason):
                    Text("Failed: \(reason)").font(.caption2).foregroundStyle(.red).lineLimit(1)
                case .cancelled:
                    Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
                case .finished:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
            if hovering {
                if item.state == .running {
                    Button(action: item.cancel) { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Cancel Download")
                } else if item.state == .finished {
                    Button(action: item.reveal) { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
        }
        // Hover buttons don't change the height.
        .frame(minHeight: 20)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.file?.path ?? item.name)
        // Opening one is your click, never the page's.
        .onTapGesture(count: 2, perform: item.open)
        .onDrag {
            guard item.state == .finished, let file = item.file else { return NSItemProvider() }
            return NSItemProvider(contentsOf: file) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open", action: item.open).disabled(item.state != .finished)
            Button("Show in Finder", action: item.reveal).disabled(item.file == nil || item.state == .running)
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.download.originalRequest?.url?.absoluteString ?? "", forType: .string)
            }
            .disabled(item.download.originalRequest?.url == nil)
            Divider()
            if item.state == .running {
                Button("Cancel Download", action: item.cancel)
            }
            Button("Remove from List") { Downloads.shared.remove(item) }
        }
    }
}

struct SpaceSwitcher: View {
    @ObservedObject var spaces: SpaceStore

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(spaces.states.enumerated()), id: \.element.space.id) { index, state in
                        SpaceDot(state: state, number: index + 1, selected: state.space.id == spaces.selected) {
                            spaces.select(state.space.id)
                        }
                        .contextMenu { SpaceMenuItems(spaces: spaces, id: state.space.id) }
                    }
                }
                // Room for the selected Space's ring (3pt out) and the sound
                // badge, which the scroll view would otherwise clip.
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            Button { spaces.prompt = .new } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New Space (⇧⌘N)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

struct SpaceDot: View {
    @ObservedObject var state: SpaceState
    let number: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(state.space.symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .background(Circle().fill(state.space.tint.opacity(selected ? 0.9 : 0.3)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.6 : 0), lineWidth: 1.5)
                    .padding(-3))
                // Throwaway Spaces wear a dashed edge: nothing here is kept.
                .overlay {
                    if state.space.isThrowaway {
                        Circle().strokeBorder(Color.primary.opacity(0.7),
                                              style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !state.audibleTabs.isEmpty {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 7, weight: .bold))
                            .padding(2.5)
                            .background(Circle().fill(.background))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help((state.space.isThrowaway ? "\(state.space.name), throwaway" : state.space.name)
              + (number <= 9 ? " (⌃\(number))" : ""))
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    /// This tab is the right-hand pane of a split view.
    let inSplit: Bool
    /// It isn't the left-hand tab, so it can go beside it.
    let canSplit: Bool
    let close: () -> Void
    let popOut: () -> Void
    let openSplit: () -> Void
    let closeSplit: () -> Void
    /// Another tab (its id, as text) was dropped on this row.
    let dropTab: ([String]) -> Bool
    /// Not in a throwaway Space, which doesn't outlive a quit.
    let canPin: Bool
    let togglePin: () -> Void
    /// Pin the page it's on now instead.
    let repin: () -> Void
    let resetPermissions: (String) -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let favicon = tab.favicon {
                    Image(nsImage: favicon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            Text(tab.displayTitle).lineLimit(1)
                .help(tab.address)
                // A sleeping pin: not loaded until you go to it.
                .foregroundStyle(tab.isAsleep ? .secondary : .primary)
            Spacer()
            if inSplit {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .foregroundStyle(.secondary)
                    .help("In split view, on the right")
            }
            if tab.isPlayingAudio || tab.isMuted {
                Button(action: tab.toggleMute) {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tab.isMuted ? "Unmute Tab" : "Mute Tab")
            }
            if hovering {
                if tab.isPinned || (canPin && ["http", "https", "file"].contains(URL(string: tab.address)?.scheme ?? "")) {
                    Button(action: togglePin) {
                        Image(systemName: tab.isPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(tab.isPinned ? "Unpin Tab" : "Pin Tab: keep it after a restart")
                }
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tab.isPinned ? "Put to sleep (stays pinned)" : "Close Tab")
            }
        }
        // One height whatever's showing, so hovering (pin, close) or a
        // sound starting doesn't nudge every tab below.
        .frame(height: 20)
        // Room to breathe between tabs.
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Drag this tab onto another to open them in a split view.
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in dropTab(items) } isTargeted: { dropTargeted = $0 }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(dropTargeted ? 0.3 : 0)))
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.address, forType: .string)
            }
            .disabled(tab.address.isEmpty)
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab", action: tab.toggleMute)
            Button("Pause Media", action: tab.pauseMedia).disabled(!tab.isPlayingAudio)
            if let site = tab.site {
                // Undo a mistaken "Don't Allow" (or a "yes"): camera, microphone,
                // notifications and opening apps, for this site in this Space.
                Button("Reset Permissions for \(site)") { resetPermissions(site) }
            }
            Divider()
            if canPin || tab.isPinned {
                Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: togglePin)
                    .disabled(!tab.isPinned && !["http", "https", "file"].contains(URL(string: tab.address)?.scheme ?? ""))
            }
            if let pinned = tab.pinnedURL, !tab.isAsleep, tab.address != pinned.absoluteString {
                Button("Back to Pinned Page", action: tab.returnToPin)
                Button("Pin This Page Instead", action: repin)
            }
            Divider()
            if inSplit {
                Button("Close Split View", action: closeSplit)
            } else {
                Button("Open in Split View", action: openSplit).disabled(!canSplit)
            }
            Button("Open in New Window", action: popOut)
            Button("Close Tab", action: close)
        }
    }
}

// MARK: Space dialogs

struct SpacePromptSheet: View {
    @ObservedObject var spaces: SpaceStore
    let prompt: SpacePrompt
    @State private var name = ""
    @State private var emoji = ""
    @State private var color = SpaceColor.blue
    @State private var throwaway = false
    /// Whether the Space being edited was throwaway when the dialog opened.
    @State private var wasThrowaway = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch prompt {
            case .new:
                nameForm(title: "New Space", action: "Create", except: nil) {
                    spaces.addSpace(named: name, color: color, emoji: emoji, throwaway: throwaway)
                }
                .onAppear { (color, emoji) = spaces.freshLook(for: "") }
            case .edit(let id):
                nameForm(title: "Edit Space", action: "Save", except: id) {
                    spaces.edit(id, name: name, color: color, emoji: emoji, throwaway: throwaway)
                }
                .onAppear {
                    guard let space = spaces.state(id)?.space else { return }
                    name = space.name
                    emoji = space.symbol
                    color = space.color ?? .blue
                    throwaway = space.isThrowaway
                    wasThrowaway = space.isThrowaway
                }
            case .delete(let id):
                let spaceName = spaces.state(id)?.space.name ?? "this Space"
                Text("Delete \(spaceName)?").font(.headline)
                Text("Its tabs close, and its cookies, logins and site data are erased. This can't be undone.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { spaces.prompt = nil }.keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive) {
                        spaces.prompt = nil
                        spaces.delete(id)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        // The colour panel goes with the dialog it was picking for.
        .onDisappear { ColorPanel.shared.close() }
    }

    @ViewBuilder
    private func nameForm(title: String, action: String, except: Space.ID?, commit: @escaping () -> Void) -> some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = spaces.isNameTaken(trimmed, except: except)
        Text(title).font(.headline)
        HStack {
            TextField("🙂", text: $emoji)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 40)
                .help("Emoji (⌃⌘Space for the picker)")
                // Keep just the newest character typed or picked.
                .onChange(of: emoji) { _, new in
                    if new.count > 1, let last = new.last { emoji = String(last) }
                }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty && !taken { spaces.prompt = nil; commit() } }
        }
        HStack(spacing: 6) {
            ForEach(SpaceColor.swatches) { choice in
                Circle()
                    .fill(choice.color)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: choice == color ? 2 : 0).padding(-3))
                    .contentShape(Circle())
                    .onTapGesture { color = choice }
                    .help(choice.rawValue.capitalized)
            }
            // Anything else, from the system colour panel.
            // Anything else: a rainbow swatch that opens the colour panel,
            // showing the custom colour once one is picked.
            Circle()
                .fill(color.isCustom
                      ? AnyShapeStyle(color.color)
                      : AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                      center: .center)))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: color.isCustom ? 2 : 0).padding(-3))
                .contentShape(Circle())
                .onTapGesture {
                    ColorPanel.shared.show(color.color) { color = SpaceColor($0) }
                }
                .help("Custom colour")
        }
        .padding(.vertical, 2)
        Toggle("Throwaway", isOn: $throwaway)
        Group {
            if except != nil && throwaway != wasThrowaway {
                Text(throwaway
                     ? "Saving closes its tabs, logs you out of everything here and erases its saved logins and history."
                     : "Saving closes its tabs. From then on, logins and history are kept on disk.")
                    .foregroundStyle(.orange)
            } else if throwaway {
                Text("Logins, site data and history stay in memory, where nothing else on your Mac can read them, and are forgotten when Adequate quits.")
            } else {
                Text("Logins, site data and history are kept on disk between launches.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if taken {
            Text("There's already a Space called \(trimmed).").font(.caption).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { spaces.prompt = nil }.keyboardShortcut(.cancelAction)
            Button(action) { spaces.prompt = nil; commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || taken)
        }
    }
}

/// The system colour panel, reporting each colour picked to whoever opened it last.
@MainActor
final class ColorPanel: NSObject {
    static let shared = ColorPanel()
    private var onChange: ((Color) -> Void)?

    func show(_ color: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.color = NSColor(color)
        panel.orderFront(nil)
    }

    func close() {
        onChange = nil
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    @objc private func changed(_ panel: NSColorPanel) {
        onChange?(Color(nsColor: panel.color))
    }
}

// MARK: Site

/// The site the tab is showing, with a padlock when every part of it came
/// over HTTPS, and a warning when it didn't. Shown where the page can't
/// reach, since the address bar is usually hidden.
struct SiteLabel: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let url = URL(string: tab.address), let scheme = url.scheme {
            let (symbol, style): (String, Color) = switch scheme {
            case "https" where tab.isSecure: ("lock.fill", .secondary)
            case "file": ("doc", .secondary)
            case "about": ("", .secondary)
            default: ("exclamationmark.triangle.fill", .orange)
            }
            if !symbol.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: symbol).foregroundStyle(style)
                    Text(Self.site(url)).foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.head)
                .help(scheme == "https" && !tab.isSecure ? "Parts of this page didn't come over HTTPS"
                      : scheme == "http" ? "Not secure: this page didn't come over HTTPS" : tab.address)
            }
        }
    }

    static func site(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        let host = url.host(percentEncoded: true) ?? url.absoluteString
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.port.map { "\(bare):\($0)" } ?? bare
    }
}

/// The site label as a small pill at the top of the window, for when the
/// sidebar is hidden.
struct SiteBadge: View {
    @ObservedObject var state: SpaceState

    var body: some View {
        if let tab = state.activeTab, !tab.address.isEmpty {
            SiteLabel(tab: tab)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

// MARK: Tab switcher

/// ⌃Tab: the Space's tabs, most recent first, while Control is held. ⌃Tab and
/// ⌃⇧Tab move the pick, letting go of Control goes there, Esc backs out.
struct TabSwitcher: View {
    @ObservedObject var state: SpaceState

    var body: some View {
        if state.isCycling {
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(state.cycleTabs) { tab in
                            TabCard(tab: tab, picked: tab.id == state.cycleTarget, tint: state.space.tint)
                                .id(tab.id)
                                .onTapGesture {
                                    state.cycle(to: tab.id)
                                    state.endCycle()
                                }
                        }
                    }
                    .padding(14)
                }
                .onAppear { scroller.scrollTo(state.cycleTarget, anchor: .center) }
                .onChange(of: state.cycleTarget) { _, target in
                    withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(target, anchor: .center) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
            .shadow(radius: 20, y: 6)
            .frame(maxWidth: TabCard.width * 5 + 10 * 4 + 28)
            .padding(40)
        }
    }
}

/// One tab in the switcher: how it looked last time it showed, or its icon
/// if it hasn't been on screen yet, with its title underneath.
struct TabCard: View {
    @ObservedObject var tab: Tab
    let picked: Bool
    let tint: Color
    static let width: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.background.secondary)
                if let snapshot = tab.snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.width, height: Self.width * 0.625, alignment: .top)
                } else if let favicon = tab.favicon {
                    Image(nsImage: favicon).resizable().interpolation(.high)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.width, height: Self.width * 0.625, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            HStack(spacing: 5) {
                if let favicon = tab.favicon, tab.snapshot != nil {
                    Image(nsImage: favicon).resizable().interpolation(.high).frame(width: 14, height: 14)
                }
                Text(tab.displayTitle).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .padding(6)
        .background(picked ? tint.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(picked ? tint : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

// MARK: Page

struct SpaceDetail: View {
    @ObservedObject var state: SpaceState

    var body: some View {
        if let tab = state.selectedTab {
            if let split = state.splitTab {
                // Two pages side by side. The active one wears the Space's colour.
                HSplitView {
                    pane(tab, active: !state.splitActive)
                    pane(split, active: state.splitActive)
                }
            } else {
                TabPage(tab: tab).id(tab.id)
            }
        } else {
            VStack(spacing: 12) {
                Text(state.space.symbol).font(.system(size: 64))
                Text(state.space.name).font(.largeTitle)
                Button("New Tab  ⌘T") { state.newTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pane(_ tab: Tab, active: Bool) -> some View {
        TabPage(tab: tab)
            .id(tab.id)
            .frame(minWidth: 240)
            .overlay {
                Rectangle()
                    .strokeBorder(active ? state.space.tint.opacity(0.8) : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .top)
    }
}

/// The page fills the whole window, right up under the title bar. The address
/// bar only floats over it while you're using it: ⌘L, or a blank tab.
struct TabPage: View {
    @ObservedObject var tab: Tab
    @State private var draft = ""
    @State private var editing = false
    @State private var suggestions: [History.Suggestion] = []
    @State private var chosen: Int?

    var body: some View {
        WebViewHost(webView: tab.webView)
            // Up under the title bar, but not under the sidebar.
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                if tab.isLoading {
                    ProgressView(value: max(tab.progress, 0.05))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if editing { addressBar }
            }
            .overlay(alignment: .topTrailing) {
                if tab.findShown && !editing { FindBar(tab: tab) }
            }
            .onAppear {
                draft = tab.address
                // A blank tab wants an address; one opened with a page wants
                // the page. A sleeping pin loads now, on first sight.
                tab.wake()
                if tab.isBlank { edit() } else { tab.focusPage() }
            }
            .onChange(of: tab.address) { _, address in
                if !editing { draft = address }
            }
            .onChange(of: tab.focusRequest) { _, _ in edit() }
    }

    private var addressBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: tab.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!tab.canGoBack).help("Back (⌘[)")
                Button(action: tab.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!tab.canGoForward).help("Forward (⌘])")
                Button(action: tab.reload) { Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise") }
                    .help(tab.isLoading ? "Stop" : "Reload (⌘R)")
                AddressField(text: $draft, onEdit: suggest, onMove: move, onSubmit: go,
                             onCancel: { finish(); tab.focusPage() }, onEndEditing: finish)
                    .frame(height: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if !suggestions.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionRow(entry: suggestion.entry, chosen: index == chosen)
                            .contentShape(Rectangle())
                            .onTapGesture { open(suggestion.entry.url) }
                            .onHover { if $0 { chosen = index } }
                    }
                }
                .padding(6)
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 12, y: 4)
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    /// Typing: suggestions from this Space's history. One whose address starts
    /// with what you typed is picked, so Return goes there.
    private func suggest(_ text: String) {
        suggestions = tab.history?.suggestions(for: text) ?? []
        chosen = suggestions.first?.isPrefix == true ? 0 : nil
    }

    private func move(_ step: Int) {
        guard !suggestions.isEmpty else { return }
        // Up past the first suggestion is back to just what you typed.
        let next = (chosen ?? -1) + step
        chosen = next < 0 ? nil : min(next, suggestions.count - 1)
    }

    private func go() {
        if let chosen, suggestions.indices.contains(chosen) {
            open(suggestions[chosen].entry.url)
        } else {
            tab.load(draft)
            finish()
        }
    }

    private func open(_ url: String) {
        tab.load(url)
        finish()
    }

    private func edit() {
        draft = tab.address
        suggestions = []
        chosen = nil
        editing = true
    }

    private func finish() {
        guard editing else { return }
        editing = false
        suggestions = []
        chosen = nil
        draft = tab.address
    }
}

/// ⌘F: a small bar in the page's corner. Typing finds as you go; Return and
/// ⌘G go to the next match, ⇧Return and ⌘⇧G the previous; Esc closes it.
struct FindBar: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            AddressField(text: Binding(get: { tab.findText }, set: { tab.findText = $0 }),
                         placeholder: "Find on page",
                         onEdit: tab.findChanged,
                         onMove: { tab.findAgain(backwards: $0 < 0) },
                         onSubmit: {
                             tab.findAgain(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                         },
                         onCancel: tab.hideFind,
                         onEndEditing: {})
                .frame(height: 20)
                // A fresh field takes the keyboard with its text selected.
                .id(tab.findRequest)
            switch tab.findResult {
            case .notFound:
                Text("Not found").foregroundStyle(.red)
            case .found(let count?):
                Text(count == 1 ? "1 match" : "\(count) matches").foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Button { tab.findAgain(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)")
            Button { tab.findAgain(backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)")
            Button(action: tab.hideFind) { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 12, y: 4)
        .padding(.trailing, 16)
        .padding(.top, 10)
    }
}

struct SuggestionRow: View {
    let entry: History.Entry
    let chosen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.title.isEmpty ? History.bare(entry.url) : entry.title)
                .lineLimit(1)
            Text(History.bare(entry.url))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(chosen ? Color.white.opacity(0.8) : .secondary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(chosen ? Color.white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor : .clear))
    }
}

/// The address box: an AppKit text field, so the arrow keys can move through
/// suggestions while you type. It takes focus as it appears, with the whole
/// address selected.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Search or enter address"
    var onEdit: (String) -> Void
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onEndEditing: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        init(parent: AddressField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onEdit(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }

        /// Clicking into the page, or anywhere that takes the keyboard.
        func controlTextDidEndEditing(_ note: Notification) { parent.onEndEditing() }
    }
}

/// Holds a tab's web view. The web view lives in a container, so when a tab
/// moves to another window, the old place letting go can't pull it back out.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = PageContainer()
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { adopt(into: container) }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func adopt(into container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        if !container.bounds.isEmpty { webView.frame = container.bounds }
        container.addSubview(webView)
    }
}

/// Holds a tab's page and keeps it the holder's size, except at 0×0.
/// SwiftUI lays a new holder out at nothing before its real size (coming
/// back to a tab), and squashes the old one as you leave. A page that keeps
/// your place by measuring the view (Slack's message list) loses it when
/// squashed and jumps back several pages, so the page keeps its last real
/// size until a real one comes along.
final class PageContainer: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard !bounds.isEmpty else { return }
        subviews.forEach { $0.frame = bounds }
    }
}
