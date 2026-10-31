// ReviewFileRail.swift
// Weir — the changed-file list, with enough on it to pick a reading order.

import AppKit
import SwiftUI

/// Each row says more than which path changed, and a file both staged and
/// unstaged is one row: size and existing feedback are what decide where to
/// start, so both are on the row.
///
/// Two layouts, because a change is either one feature spread across the tree
/// or one directory reworked, and the useful order differs. Both filter from
/// the same field: a change of any size outgrows a list you can only scroll.
struct ReviewFileRail: View {
    let root: URL
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
    /// A transient compact-width drawer does not share horizontal space with
    /// the diff, so it supplies its own width instead of using the inline
    /// rail's readability clamp.
    var widthOverride: CGFloat?
    /// Present only when the rail is a drawer. The inline rail has no close
    /// affordance because its divider and the window width own its visibility.
    var onClose: (() -> Void)?

    @Environment(\.weirAccent) private var accent
    @Environment(\.locale) private var locale
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity
    /// Read here rather than passed in: the width changes on every frame of a
    /// divider drag, and a workspace that read it would rebuild the diff table
    /// beside this list on each one.
    @Environment(ReviewPresentation.self) private var reviewPresentation
    /// The filter and the folded sections, held for the review tab the
    /// window shows rather than by this view, so neither is lost as the
    /// list goes from the screen (a filter that matches nothing, the tab
    /// going with its project) and comes back. Folds are keyed by section
    /// id; both kinds of heading use them, and their ids are namespaced,
    /// so the layout switch does not carry one mode's folds into the
    /// other's.
    @Environment(ReviewTabDisplay.self) private var display
    /// Where each heading currently sits, measured from the top of the list.
    /// Only the visible ones report, which is all the pinned heading needs:
    /// the one to draw is the last that crossed zero. Not state: every
    /// heading reports on every frame of a scroll, and a state written that
    /// often drew the whole list again each frame, its sections worked out
    /// from every file four times over. Only `pin`, what is drawn, is state.
    @State private var headerOffsets = ReviewRailHeaderOffsets()
    /// The pinned heading and how far the next one has pushed it, written
    /// only when either changes (`ReviewRailPin`).
    @State private var pin = ReviewRailPin.none

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
        let query = display.fileFilter
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
        // Worked out once a pass: each was read several times below, and
        // each read filtered and grouped every file again.
        let sections = sections
        let showsHeadings = showsHeadings
        VStack(spacing: 0) {
            modeBar
            searchField
            Divider()
            if sections.isEmpty {
                SupervisionEmptyState(.noMatchingFiles, size: .regular)
            } else {
                list(sections, showsHeadings: showsHeadings)
            }
        }
        .frame(width: width)
        // Read as the "Changed Files" navigation, so VoiceOver can
        // jump between it and the diff.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Changed Files", comment: "Review: VoiceOver's name for the file list"))
        // A filter left over from before a refresh hides files the reader is
        // expecting to see, with nothing on screen explaining where they went.
        .onChange(of: files) { _, _ in
            display.fileFilter = ""
        }
    }

    /// The width this list actually takes, clamped so the diff keeps its own.
    private var width: CGFloat {
        widthOverride ?? ReviewRail.width(reviewPresentation.railWidth, in: available) ?? ReviewRail.minimum
    }

    private func list(_ sections: [RailSection], showsHeadings: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    if showsHeadings {
                        header(section)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .named(Self.space)).minY.rounded()
                            } action: { minY in
                                headerOffsets.values[section.id] = minY
                                updatePin()
                            }
                    }
                    // A fold left from when the range had headings would hide
                    // its files with nothing to unfold them by.
                    if !showsHeadings || !display.collapsedSections.contains(section.id) {
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
            .padding(.bottom, WeirLayout.Supervision.spaceSnug)
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
        .contentMargins(.top, showsHeadings ? Self.headerHeight : 0, for: .scrollIndicators)
        .overlay(alignment: .top) {
            if showsHeadings, let stuck = sections.first(where: { $0.id == pin.id }) {
                // Clipped to one heading's height. The offset that lets the
                // next heading push this one away moves it above the list, and
                // an overlay is not clipped by the view it sits on: it rode up
                // over the filter field.
                header(stuck)
                    .offset(y: pin.offset)
                    .frame(height: Self.headerHeight, alignment: .top)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: isTree) { _, _ in forgetHeaderOffsets() }
        .onChange(of: display.fileFilter) { _, _ in forgetHeaderOffsets() }
        .onChange(of: files) { _, _ in forgetHeaderOffsets() }
    }

    // MARK: - Chrome

    private var modeBar: some View {
        HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            // The heading reads as words, "Files · 0 / 2 viewed", in the
            // supervision window's muted.
            Text("Files")
                .font(.supervision(.meta))
                .foregroundStyle(SupervisionTokens.muted.color)
            Text(verbatim: ReviewStackText.progress(
                ReviewReadingProgress(fileIDs: files.map(\.id), viewed: viewed),
                locale: locale
            ))
            .font(.supervision(.meta).monospacedDigit())
            .foregroundStyle(SupervisionTokens.muted.color)
            .lineLimit(1)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(verbatim: ReviewStackText.spokenProgress(
                ReviewReadingProgress(fileIDs: files.map(\.id), viewed: viewed),
                locale: locale
            )))
            .help(hidesViewed && hiddenCount > 0
                ? Text("\(hiddenCount) files hidden")
                : Text("Changed files"))
            Spacer(minLength: WeirLayout.Supervision.spaceXS)
            viewedFilter
            // The window's one segmented control, compact for the bar, so the
            // layout's choice is marked and moved by ← → as the others are.
            SupervisionSegmentedPicker(
                Text("File List Layout"),
                selection: $isTree,
                options: [
                    .init(false, Text(Image(systemName: "list.bullet")).accessibilityLabel(Text("Flat List"))),
                    .init(true, Text(Image(systemName: "folder")).accessibilityLabel(Text("Folder Tree")))
                ],
                isCompact: true
            )
            .fixedSize()
            .help(Text("Flat list or folder tree"))
            if let onClose {
                DismissGlyphButton(label: "Close", action: onClose)
            }
        }
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
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
                    .font(.supervision(.caption))
                    .foregroundStyle(hidesViewed ? accent : SupervisionTokens.muted.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(hidesViewed ? "Show Viewed Files" : "Hide Viewed Files"))
            .accessibilityAddTraits(hidesViewed ? [.isSelected] : [])
            .help(Text(hidesViewed ? "Show Viewed Files" : "Hide Viewed Files"))
        }
    }

    private var searchField: some View {
        @Bindable var display = display
        return HStack(spacing: WeirLayout.Supervision.spaceXS) {
            Image(systemName: "magnifyingglass")
                .font(.supervision(.micro))
                .foregroundStyle(SupervisionTokens.muted.color)
            TextField("Filter files", text: $display.fileFilter)
                .textFieldStyle(.plain)
                .font(.supervision(.caption))
            if !display.fileFilter.isEmpty {
                Button {
                    display.fileFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.supervision(.micro))
                        .foregroundStyle(SupervisionTokens.muted.color)
                }
                .buttonStyle(.plain)
                .iconButtonHelp("Clear")
            }
        }
        .searchFieldFace(.rail)
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
        .padding(.bottom, WeirLayout.Supervision.spaceSnug)
    }

    // MARK: - Sections

    /// One heading and the rows under it. The two layouts differ only in how
    /// files are grouped, so pinning, collapsing and the heading itself are
    /// written once against this.
    private struct RailSection: Identifiable, Equatable {
        let id: String
        /// A layer's name, or a directory path shown as is.
        let title: DisplayText
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
                    title: .localized(layer.title),
                    files: layerFiles
                )
            }
        }
        return ReviewFileTree.directories(ordered).map { group in
            RailSection(
                id: "dir:" + group.path,
                title: group.path.isEmpty ? .localized("Repository root") : .verbatim(group.path),
                files: group.files
            )
        }
    }

    /// Over the whole range rather than the filter's matches, so typing in
    /// the filter does not take the headings away
    /// (`ReviewFileTree.showsLayerHeadings`).
    private var showsHeadings: Bool {
        ReviewFileTree.showsLayerHeadings(files: files, isTree: isTree)
    }

    private func updatePin() {
        let next = ReviewRailPin.of(headerOffsets.values, headerHeight: Self.headerHeight)
        if next != pin {
            pin = next
        }
    }

    private func forgetHeaderOffsets() {
        headerOffsets.values.removeAll()
        updatePin()
    }

    private func header(_ section: RailSection) -> some View {
        let id = section.id
        let title = section.title
        let count = section.files.count
        let isCollapsed = display.collapsedSections.contains(id)
        // A `Button` rather than a tap gesture with the button traits bolted
        // on: Full Keyboard Access reaches a real button, and a heading that
        // folds only for the mouse is a heading half the readers cannot use.
        return Button {
            toggle(id)
        } label: {
            HStack(spacing: WeirLayout.Supervision.spaceXS) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.supervision(.disclosure, weight: .semibold))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .frame(width: 9)
                    .accessibilityHidden(true)
                // A layer heading folds away like a directory one. They are drawn
                // the same and sit in the same column, and one of them not
                // answering a click read as a heading that had failed rather than
                // one that was never meant to.
                Text(display: title)
                    .lineLimit(1)
                    .supervisionTruncation(.pathTitle)
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                Spacer(minLength: WeirLayout.Supervision.spaceXS)
            }
            .font(.caption2.weight(.semibold))
            // The heading and its count in one tone: the system's secondary
            // gray stood under 4.5:1 here.
            .foregroundStyle(SupervisionTokens.muted.color)
            .padding(.leading, Self.contentLeading)
            .padding(.trailing, Self.contentTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.headerHeight)
            // Two coats. A pinned header sits over the rows scrolling past it,
            // and the column tint alone is translucent, so the row underneath
            // showed through and read as a header that had failed to pin.
            .background {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                Rectangle().fill(WeirColor.reviewAsideBackground)
            }
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(display: title))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(display: title))
        .accessibilityValue(Text(isCollapsed ? "Collapsed" : "Expanded"))
        .accessibilityAddTraits(.isHeader)
    }

    private func toggle(_ id: String) {
        if display.collapsedSections.contains(id) {
            display.collapsedSections.remove(id)
        } else {
            display.collapsedSections.insert(id)
        }
    }

    // MARK: - Rows

    /// One file, with a checkbox before it, outside the row's button,
    /// so checking a file does not also scroll to it.
    private func row(
        _ file: ReviewFile,
        name: String? = nil,
        showsParent: Bool = true
    ) -> some View {
        let isSelected = file.id == selection
        let isViewed = viewed.contains(file.id)
        return HStack(alignment: .top, spacing: 0) {
            ReviewViewedCheckbox(path: file.path, isViewed: isViewed) {
                onToggleViewed(file.id)
            }
            .controlSize(.small)
            .padding(.leading, Self.contentLeading)
            .padding(.vertical, WeirLayout.Supervision.spaceXS)
            rowButton(file, name: name, showsParent: showsParent, leading: 7)
        }
        // Read files keep their place and fade only their name
        // (`rowButton`), so the checkbox and the counts stay legible.
        .background(isSelected ? SupervisionTokens.selection.color.opacity(surfaceOpacity) : .clear)
    }

    private func rowButton(
        _ file: ReviewFile,
        name: String?,
        showsParent: Bool,
        leading: CGFloat
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
            VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceHairline) {
                HStack(spacing: WeirLayout.Supervision.spaceSnug) {
                    // The checkbox carries the mark, and the comment count
                    // follows the name.
                    Text(verbatim: name ?? ReviewFileTree.name(file.path))
                        .font(.supervision(.row))
                        .lineLimit(1)
                        // The tail, not the middle: these names share their
                        // extension, so middle truncation spent its budget
                        // restoring `.swift` and left six characters of a stem
                        // that also begins the same way. The whole path is on
                        // the row's tooltip either way.
                        .supervisionTruncation(.name)
                        .foregroundStyle(nameColor(isSelected: isSelected, isViewed: isViewed))
                        // The name is what the row is for. Without this the
                        // change counts kept their full width and the tree
                        // truncated names to a few characters.
                        .layoutPriority(1)
                    if count > 0 {
                        commentCount(count)
                    }
                    Spacer(minLength: WeirLayout.Supervision.spaceXS)
                    ReviewDiffCounts(stat: stats[file.id], size: .caption, spacing: WeirLayout.Supervision.spaceXS)
                }
                if showsParent, let parent = ReviewFileTree.parent(file.path) {
                    Text(verbatim: parent)
                        .font(.supervisionCode(beside: .meta))
                        .lineLimit(1)
                        .supervisionTruncation(.pathTitle)
                        // `muted`, where the folder has to read at 4.5:1.
                        .foregroundStyle(SupervisionTokens.muted.color)
                }
            }
            // No extra indent under a directory heading: the heading is a
            // full-width band and its files are the only thing beneath it, so
            // the step said nothing the band had not already said — it only
            // pushed the row's marker out of line with the heading's chevron.
            .padding(.leading, leading)
            .padding(.trailing, Self.contentTrailing)
            .padding(.vertical, WeirLayout.Supervision.spaceXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A plain button derives its hit test from drawn descendants, not
            // from the flexible frame around them. Give that frame a shape so
            // the empty part of the row selects the same file as its name.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // No "Mark as Viewed" here: the checkbox is the mark, and the
            // band's button is the one that moves the viewed line.
            ReviewFileActionsMenu(root: root, file: file)
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
            comments: count,
            isViewed: isViewed,
            locale: locale
        )))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// A read file's name steps back to `muted`, which still reads at 4.5:1,
    /// unless it is the file selected, which is in the text color
    /// like every unread one.
    private func nameColor(isSelected: Bool, isViewed: Bool) -> Color {
        isViewed && !isSelected ? SupervisionTokens.muted.color : SupervisionTokens.text.color
    }

    /// How many comments the file has, after its name.
    private func commentCount(_ count: Int) -> some View {
        Text(verbatim: "\(count)")
            .font(.supervision(.glyph, weight: .bold, design: .monospaced))
            .foregroundStyle(accent)
            .frame(width: 14, height: 14)
            .background(Circle().fill(accent.opacity(0.2)))
    }
}

/// File-system actions on a rail row. Resolving at invocation time keeps
/// moved applications and symlinks out of the view state.
struct ReviewFileActionsMenu: View {
    let root: URL
    let file: ReviewFile

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ToastCenter.self) private var toastCenter

    private var fileURL: URL? {
        ReviewFileAction.fileURL(for: file.path, in: root)
    }

    private var application: FileApplicationResolution {
        FileOpener.application(for: settingsStore.settings.advanced.fileApplication)
    }

    var body: some View {
        Button("Copy Relative Path") {
            copy(file.path)
        }
        Button("Copy Absolute Path") {
            if let fileURL {
                copy(fileURL.path)
            }
        }
        .disabled(fileURL == nil)
        Button(application.openActionTitle) {
            guard let fileURL else { return }
            Task {
                do {
                    try await FileOpener.open(fileURL, with: application)
                } catch {
                    toastCenter.showInFrontWindow(ToastItem(message: DisplayText(error: error), undo: nil))
                }
            }
        }
        .disabled(fileURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
        Button("Show in Finder") {
            guard let fileURL else { return }
            let target = FileManager.default.fileExists(atPath: fileURL.path)
                ? fileURL
                : fileURL.deletingLastPathComponent()
            ReviewFileAction.revealInFinder(target)
        }
        .disabled(fileURL == nil)
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// The file rail's headings' offsets from the top of the list, as each
/// last reported. A reference, held in state only to live as long as the
/// rail: writing it redraws nothing.
@MainActor
final class ReviewRailHeaderOffsets {
    var values: [String: CGFloat] = [:]
}

/// The heading the file rail pins over its list: the last one to have
/// crossed the top, pushed up by the next one as it arrives, so the two
/// never overlap.
struct ReviewRailPin: Equatable {
    let id: String?
    let offset: CGFloat

    static let none = ReviewRailPin(id: nil, offset: 0)

    /// At zero the source heading is already pinned by the scroll view;
    /// drawing ours there too doubled it at rest and showed a seam as the
    /// compact drawer moved into place. So a heading is pinned only once it
    /// is above the top.
    static func of(_ offsets: [String: CGFloat], headerHeight: CGFloat) -> Self {
        let stuck = offsets.filter { $0.value < 0 }.max { $0.value < $1.value }?.key
        let next = offsets.values.filter { $0 > 0 }.min() ?? .greatestFiniteMagnitude
        return ReviewRailPin(id: stuck, offset: next < headerHeight ? next - headerHeight : 0)
    }
}
