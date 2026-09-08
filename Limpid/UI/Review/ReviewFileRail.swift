// ReviewFileRail.swift
// Limpid — the changed-file list, with enough on it to pick a reading order.

import SwiftUI

/// The list used to say only which paths changed, and said the same path twice
/// when a file was both staged and unstaged. Size and existing feedback are
/// what decide where to start, so both are on the row.
///
/// Two layouts, because a change is either one feature spread across the tree
/// or one directory reworked, and the useful order differs. Both filter from
/// the same field: a change of any size outgrows a list you can only scroll.
struct ReviewFileRail: View {
    let files: [ReviewFile]
    let stats: [String: ReviewFileStat]
    let commentCounts: [String: Int]
    /// Files the reader has finished with, by `ReviewFile.id`.
    let viewed: Set<String>
    let selection: String?
    /// Owned by the workspace so the choice survives a reload of the list.
    @Binding var isTree: Bool
    /// Likewise owned above: a filter that reset itself every time the change
    /// list refreshed would put back the files the reader had just cleared.
    @Binding var hidesViewed: Bool
    let onSelect: (String) -> Void
    let onToggleViewed: (String) -> Void
    /// How wide the surface is. Passed in rather than measured here: the
    /// divider drag changes this view's own width every frame, and reading it
    /// from a geometry reader would rebuild the diff table beside it each time.
    let available: CGFloat

    @Environment(\.limpidAccent) private var accent
    /// Read here rather than passed in: the width changes on every frame of a
    /// divider drag, and a workspace that read it would rebuild the diff table
    /// beside this list on each one.
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @State private var query = ""
    /// Sections the reader has folded away, keyed by section id. Both kinds
    /// of heading use it, and their ids are namespaced, so the layout switch
    /// does not carry one mode's folds into the other's.
    @State private var collapsed: Set<String> = []
    /// Where each heading currently sits, measured from the top of the list.
    /// Only the visible ones report, which is all the pinned heading needs:
    /// the one to draw is the last that crossed zero.
    @State private var headerOffsets: [String: CGFloat] = [:]

    /// `nonisolated` so the geometry closure can name it: the reader is on the
    /// main actor, but the closure is not, and a coordinate space name has no
    /// state to protect.
    private nonisolated static let space = "review-file-rail"
    private static let contentLeading: CGFloat = 10
    /// Wider than the leading inset by the width of an overlay scroller's
    /// knob. The list scrolls in every repository worth reviewing, and macOS
    /// draws that scroller over the content — it sat on the change counts and
    /// on the pinned heading's own count. Only as wide as the knob, though:
    /// reserving the scroller's full lane left a band of empty rail beside it.
    private static let contentTrailing: CGFloat = 12
    /// Fixed, because the heading arriving behind the pinned one is offset by
    /// exactly this to push it off.
    private static let headerHeight: CGFloat = 24

    private var matches: [ReviewFile] {
        var result = ReviewFileTree.listed(
            files,
            hidingViewed: hidesViewed,
            viewed: viewed,
            open: selection
        )
        // The text filter is this list's own: it is a search rather than a
        // scope, and the keys that walk the files do not follow it.
        if !query.isEmpty {
            result = result.filter { $0.path.localizedCaseInsensitiveContains(query) }
        }
        return result
    }

    /// How many files the mark is currently holding back, which is what the
    /// control has to say for itself when it is on.
    private var hiddenCount: Int {
        files.count { viewed.contains($0.id) && $0.id != selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            searchField
            Divider()
            if matches.isEmpty {
                Text("No matching files.")
                    .font(LimpidFont.caption)
                    .foregroundStyle(LimpidColor.tertiaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                list
            }
        }
        .frame(width: width)
        .background(LimpidColor.tabColumnBackground)
        // A filter left over from before a refresh hides files the reader is
        // expecting to see, with nothing on screen explaining where they went.
        .onChange(of: files) { _, _ in
            query = ""
        }
    }

    /// The width this list actually takes, clamped so the diff keeps its own.
    private var width: CGFloat {
        ReviewRail.width(reviewPresentation.railWidth, in: available) ?? ReviewRail.minimum
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    header(section)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named(Self.space)).minY.rounded()
                        } action: { minY in
                            headerOffsets[section.id] = minY
                        }
                    if !collapsed.contains(section.id) {
                        ForEach(section.files) { file in
                            row(
                                file,
                                name: isTree ? ReviewFileTree.name(file.path) : nil,
                                showsParent: !isTree
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 6)
            // Rebuilt when the layout changes rather than updated in place. A
            // row keeps its identity across the switch — the same file — and
            // `LazyVStack` left the ones already on screen drawn the old way:
            // parent paths in tree mode, and a stale selection highlight.
            .id(isTree)
        }
        .coordinateSpace(.named(Self.space))
        // The pinned heading is drawn over the scroll view, so it was drawn
        // over the top of the scroller too — which read as a scroller with its
        // end cut off. Starting the indicator below the heading gives it the
        // whole lane it is allowed to use.
        .contentMargins(.top, Self.headerHeight, for: .scrollIndicators)
        .overlay(alignment: .top) {
            if let stuck = sections.first(where: { $0.id == stuckID }) {
                // Clipped to one heading's height. The offset that lets the
                // next heading push this one away moves it above the list, and
                // an overlay is not clipped by the view it sits on: it rode up
                // over the filter field.
                header(stuck)
                    .offset(y: stuckOffset)
                    .frame(height: Self.headerHeight, alignment: .top)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: isTree) { _, _ in headerOffsets.removeAll() }
        .onChange(of: query) { _, _ in headerOffsets.removeAll() }
        .onChange(of: files) { _, _ in headerOffsets.removeAll() }
    }

    // MARK: - Chrome

    private var modeBar: some View {
        HStack(spacing: 6) {
            Text("Files")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LimpidColor.secondaryText)
                .textCase(.uppercase)
            Text(verbatim: "\(matches.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LimpidColor.tertiaryText)
                .contentShape(Rectangle())
                .help(hidesViewed && hiddenCount > 0
                    ? Text("\(hiddenCount) files hidden")
                    : Text("Changed files"))
            Spacer(minLength: 4)
            viewedFilter
            Picker("Files", selection: $isTree) {
                Image(systemName: "list.bullet")
                    .accessibilityLabel(Text("Flat list"))
                    .tag(false)
                Image(systemName: "folder")
                    .accessibilityLabel(Text("Folder tree"))
                    .tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .accessibilityLabel(Text("File List Layout"))
            // On the control rather than on each segment: AppKit draws this as
            // one `NSSegmentedControl`, and a tooltip attached to a segment's
            // label never reaches it.
            .help(Text("Flat list or folder tree"))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    /// Hides what has been read. Only offered once something has been marked:
    /// a control that can do nothing is a control the reader has to work out
    /// the meaning of.
    @ViewBuilder
    private var viewedFilter: some View {
        if !viewed.isEmpty {
            Button {
                hidesViewed.toggle()
            } label: {
                Image(systemName: hidesViewed ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(hidesViewed ? accent : LimpidColor.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(hidesViewed ? "Show Viewed Files" : "Hide Viewed Files"))
            .accessibilityAddTraits(hidesViewed ? [.isSelected] : [])
            .help(Text(hidesViewed ? "Show Viewed Files" : "Hide Viewed Files"))
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(LimpidColor.tertiaryText)
            TextField("Filter files", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(LimpidColor.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LimpidColor.rowHoverFill)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Sections

    /// One heading and the rows under it. The two layouts differ only in how
    /// files are grouped, so pinning, collapsing and the heading itself are
    /// written once against this.
    private struct RailSection: Identifiable, Equatable {
        let id: String
        let title: String
        let files: [ReviewFile]
    }

    private var sections: [RailSection] {
        let ordered = ReviewFileTree.ordered(matches, isTree: isTree)
        guard isTree else {
            return ReviewLayer.allCases.compactMap { layer in
                let layerFiles = ordered.filter { $0.layer == layer }
                guard !layerFiles.isEmpty else { return nil }
                return RailSection(
                    id: "layer:" + layer.rawValue,
                    title: layer.title,
                    files: layerFiles
                )
            }
        }
        return ReviewFileTree.directories(ordered).map { group in
            RailSection(
                id: "dir:" + group.path,
                title: group.path.isEmpty ? String(localized: "Repository root") : group.path,
                files: group.files
            )
        }
    }

    /// The heading the reader is under: the last one to have crossed the top.
    private var stuckID: String? {
        sections
            .filter { (headerOffsets[$0.id] ?? .greatestFiniteMagnitude) <= 0 }
            .max { (headerOffsets[$0.id] ?? 0) < (headerOffsets[$1.id] ?? 0) }?
            .id
    }

    /// The next heading pushes the stuck one off rather than replacing it, so
    /// the two never overlap while one is arriving.
    private var stuckOffset: CGFloat {
        let next = sections
            .compactMap { headerOffsets[$0.id] }
            .filter { $0 > 0 }
            .min() ?? .greatestFiniteMagnitude
        return next < Self.headerHeight ? next - Self.headerHeight : 0
    }

    private func header(_ section: RailSection) -> some View {
        let id = section.id
        let title = section.title
        let count = section.files.count
        let isCollapsed = collapsed.contains(id)
        // A `Button` rather than a tap gesture with the button traits bolted
        // on: Full Keyboard Access reaches a real button, and a heading that
        // folds only for the mouse is a heading half the readers cannot use.
        return Button {
            toggle(id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LimpidColor.tertiaryText)
                    .frame(width: 9)
                    .accessibilityHidden(true)
                // A layer heading folds away like a directory one. They are drawn
                // the same and sit in the same column, and one of them not
                // answering a click read as a heading that had failed rather than
                // one that was never meant to.
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .foregroundStyle(LimpidColor.tertiaryText)
                Spacer(minLength: 4)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(LimpidColor.secondaryText)
            .padding(.leading, Self.contentLeading)
            .padding(.trailing, Self.contentTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.headerHeight)
            // Two coats. A pinned header sits over the rows scrolling past it,
            // and the column tint alone is translucent, so the row underneath
            // showed through and read as a header that had failed to pin.
            .background {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                Rectangle().fill(LimpidColor.tabColumnBackground)
            }
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: title))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(isCollapsed ? "Collapsed" : "Expanded"))
        .accessibilityAddTraits(.isHeader)
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) {
            collapsed.remove(id)
        } else {
            collapsed.insert(id)
        }
    }

    // MARK: - Rows

    private func row(
        _ file: ReviewFile,
        name: String? = nil,
        showsParent: Bool = true
    ) -> some View {
        let isSelected = file.id == selection
        let count = commentCounts[file.id] ?? 0
        let isViewed = viewed.contains(file.id)
        return Button {
            onSelect(file.id)
        } label: {
            // Two lines rather than one: real repository paths do not fit the
            // rail at the width it opens at, and truncating the middle of a
            // single line left rows like "…tteActions.swift" that name nothing.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    marker(count, isViewed: isViewed)
                    Text(verbatim: name ?? ReviewFileTree.name(file.path))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        // The tail, not the middle: these names share their
                        // extension, so middle truncation spent its budget
                        // restoring `.swift` and left six characters of a stem
                        // that also begins the same way. The whole path is on
                        // the row's tooltip either way.
                        .truncationMode(.tail)
                        .foregroundStyle(
                            isSelected ? LimpidColor.primaryText : LimpidColor.secondaryText
                        )
                        // The name is what the row is for. Without this the
                        // change counts kept their full width and the tree
                        // truncated names to a few characters.
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    statLabel(stats[file.id])
                }
                if showsParent, let parent = ReviewFileTree.parent(file.path) {
                    Text(verbatim: parent)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(LimpidColor.tertiaryText)
                        .padding(.leading, 21)
                }
            }
            // No extra indent under a directory heading: the heading is a
            // full-width band and its files are the only thing beneath it, so
            // the step said nothing the band had not already said — it only
            // pushed the row's marker out of line with the heading's chevron.
            .padding(.leading, Self.contentLeading)
            .padding(.trailing, Self.contentTrailing)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Edge to edge, and square: an inset rounded pill reads as one
            // item lifted out of the list, and what is wanted here is the row
            // the reader is on. The inset lives in the content instead.
            .background(isSelected ? LimpidColor.rowActiveFill : .clear)
            // Faded rather than hidden or sorted away: a file that has been
            // read is still part of the change, and a reader who wants to go
            // back to it has to be able to find it where they left it.
            .opacity(isViewed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isViewed ? "Mark as Not Viewed" : "Mark as Viewed") {
                onToggleViewed(file.id)
            }
        }
        // Before the accessibility element below, not after it: the row's name
        // is truncated to the rail's width and the tooltip is how the rest of
        // the path is read, and `.accessibilityElement(children: .ignore)`
        // rebuilds the element that a later `.help` would have attached to.
        .help(Text(verbatim: file.path))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: file.path))
        // Composed as one string rather than added together: `Text` addition
        // is deprecated as of macOS 26, and the parts are read as one phrase.
        .accessibilityValue(Text(verbatim: ReviewFileTree.summary(
            layer: file.layer,
            stat: stats[file.id],
            comments: count
        ) + (isViewed ? " " + String(localized: "Viewed") : "")))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func marker(_ count: Int, isViewed: Bool) -> some View {
        if count > 0 {
            Text(verbatim: "\(count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(width: 14, height: 14)
                .background(Circle().fill(accent.opacity(0.2)))
        } else if isViewed {
            // In the dot's place rather than beside it: the row is 232pt wide
            // at its default, and the name is what has to survive.
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LimpidColor.tertiaryText)
                .frame(width: 14, height: 14)
        } else {
            Circle()
                .fill(LimpidColor.tertiaryText.opacity(0.4))
                .frame(width: 4, height: 4)
                .frame(width: 14, height: 14)
        }
    }

    /// Untracked files have no Git record to count against, so their stat is
    /// absent and the row keeps the space for the name instead.
    @ViewBuilder
    private func statLabel(_ stat: ReviewFileStat?) -> some View {
        if let stat {
            if stat.isBinary {
                Text("binary")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(LimpidColor.tertiaryText)
                    .fixedSize()
            } else {
                HStack(spacing: 3) {
                    Text(verbatim: "+\(stat.added)")
                        .foregroundStyle(LimpidColor.success)
                    Text(verbatim: "−\(stat.removed)")
                        .foregroundStyle(LimpidColor.error)
                }
                .font(.system(size: 9, design: .monospaced))
                // Never wrapped: the name has the layout priority, and without
                // this the counts folded onto two lines to give it room.
                .fixedSize()
            }
        }
    }
}
