import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: FileScanViewModel
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if !viewModel.showsWorkSurface {
                FlaccerLaunchView(viewModel: viewModel)
                    .ignoresSafeArea()
            } else {
                FlaccerMainSplit(viewModel: viewModel)
                .padding(14)
                .background(FlaccerColors.window)
            }
        }
        .background(viewModel.showsWorkSurface ? FlaccerColors.window : Color.black)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            viewModel.handleDrop(providers: providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(FlaccerColors.blue, lineWidth: 2)
                    .padding(10)
            }
        }
        .alert("Flaccer", isPresented: errorAlertBinding) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Move to Trash?", isPresented: trashAlertBinding) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelTrashRequest()
            }
            Button("Move to Trash", role: .destructive) {
                viewModel.confirmMoveRequestedToTrash()
            }
        } message: {
            Text(trashMessage)
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.errorMessage = nil
                }
            }
        )
    }

    private var trashAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.trashRequest != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelTrashRequest()
                }
            }
        )
    }

    private var trashMessage: String {
        guard let request = viewModel.trashRequest else {
            return ""
        }
        if request.results.count == 1, let result = request.results.first {
            return "Move \(result.fileName) to Trash?"
        }
        return "Move \(request.results.count) selected files to Trash?"
    }
}

private struct FlaccerMainSplit: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        HStack(spacing: 12) {
            FlaccerSidebar(viewModel: viewModel)
                .frame(width: 320)

            Divider()
                .overlay(Color.black.opacity(0.45))

            FlaccerDetailPane(viewModel: viewModel)
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FlaccerLaunchView: View {
    @ObservedObject var viewModel: FileScanViewModel
    @State private var targeted = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button {
                    if !isLoading {
                        viewModel.showOpenPanel()
                    }
                } label: {
                    launchContent
                    .frame(
                        width: min(proxy.size.width * 0.58, 610),
                        height: min(proxy.size.height * 0.40, 250)
                    )
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(targeted ? FlaccerColors.blue.opacity(0.9) : Color.white.opacity(0.20), lineWidth: targeted ? 1.5 : 0.9)
                    )
                }
                .buttonStyle(.plain)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                    viewModel.handleDrop(providers: providers)
                    return true
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
    }

    @ViewBuilder
    private var launchContent: some View {
        if isLoading {
            VStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.70))
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 12) {
                    Text(loadingTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(loadingSubtitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))

                    LaunchProgressBar(progress: viewModel.progressCompleted > 0 ? 1 : nil)
                        .frame(width: 260)
                        .padding(.top, 4)
                }
            }
        } else {
            VStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.70))
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 10) {
                    Text("Drop your tracks here")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Detect fake lossless files before your next gig.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))

                    Text("Choose Files or Playlists")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .padding(.top, 6)
                }
            }
        }
    }

    private var isLoading: Bool {
        viewModel.isPreparingScan || viewModel.isScanning
    }

    private var loadingTitle: String {
        viewModel.isPreparingScan ? "Preparing files" : "Analyzing tracks"
    }

    private var loadingSubtitle: String {
        if viewModel.progressTotal > 0 {
            return "Analyzing \(viewModel.progressTotal) queued track\(viewModel.progressTotal == 1 ? "" : "s")."
        }
        return "Finding supported audio files."
    }
}

private struct LaunchProgressBar: View {
    let progress: Double?
    @State private var indeterminateOffset: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))

                if let progress {
                    Capsule(style: .continuous)
                        .fill(FlaccerColors.blue)
                        .frame(width: max(12, proxy.size.width * min(max(progress, 0), 1)))
                } else {
                    Capsule(style: .continuous)
                        .fill(FlaccerColors.blue)
                        .frame(width: proxy.size.width * 0.34)
                        .offset(x: indeterminateOffset * proxy.size.width)
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule(style: .continuous))
        .onAppear {
            guard progress == nil else {
                return
            }
            indeterminateOffset = -0.34
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false)) {
                indeterminateOffset = 1.0
            }
        }
    }
}

private struct FlaccerSidebar: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusStrip(viewModel: viewModel)
            CompactDropTarget(viewModel: viewModel)
            FilterChips(viewModel: viewModel)
            ResultCards(viewModel: viewModel)
            Spacer(minLength: 0)
            SidebarFooter(viewModel: viewModel)
        }
    }
}

private struct StatusStrip: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(FlaccerColors.green)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlaccerColors.green)

            Spacer()

            SettingsLink {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlaccerColors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(FlaccerColors.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusText: String {
        if viewModel.isPreparingScan {
            return "Preparing"
        }
        if viewModel.isScanning {
            return "Analyzing"
        }
        return "Local Only"
    }
}

private struct CompactDropTarget: View {
    @ObservedObject var viewModel: FileScanViewModel
    @State private var targeted = false

    var body: some View {
        Button {
            viewModel.showOpenPanel()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.scanItems.isEmpty ? "Drop files or playlists" : "Drop more files")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(".wav .aiff .mp3 .flac .aac .m3u .xml")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FlaccerColors.textMuted)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .background(FlaccerColors.drop, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(targeted ? FlaccerColors.blue : FlaccerColors.stroke, lineWidth: targeted ? 1.5 : 0.75)
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            viewModel.handleDrop(providers: providers)
            return true
        }
    }
}

private struct FilterChips: View {
    @ObservedObject var viewModel: FileScanViewModel

    private let order: [SpectrumVerdict] = [.all, .fake, .medium, .lossless, .error]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chipRow(style: .full)
            chipRow(style: .compact)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }

    private func chipRow(style: FilterChipLabelStyle) -> some View {
        HStack(spacing: 5) {
            ForEach(visibleFilters) { verdict in
                Button {
                    viewModel.filter = verdict
                } label: {
                    Text(chipTitle(for: verdict, style: style))
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(viewModel.filter == verdict ? chipAccent(for: verdict) : FlaccerColors.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(chipBackground(for: verdict), in: Capsule(style: .continuous))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(viewModel.filter == verdict ? chipAccent(for: verdict).opacity(0.85) : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(chipTitle(for: verdict, style: .full))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleFilters: [SpectrumVerdict] {
        order.filter { verdict in
            verdict != .error || viewModel.count(for: verdict) > 0
        }
    }

    private func chipTitle(for verdict: SpectrumVerdict, style: FilterChipLabelStyle) -> String {
        let count = viewModel.count(for: verdict)
        if style == .compact {
            switch verdict {
            case .all:
                return "All \(count)"
            case .lossless:
                return "Loss \(count)"
            case .medium:
                return "Med \(count)"
            case .fake:
                return "Fake \(count)"
            case .error:
                return "Err \(count)"
            }
        }

        switch verdict {
        case .all:
            return "All (\(count))"
        case .lossless:
            return "Lossless (\(count))"
        case .medium:
            return "Medium (\(count))"
        case .fake:
            return "Fake (\(count))"
        case .error:
            return "Error (\(count))"
        }
    }

    private func chipAccent(for verdict: SpectrumVerdict) -> Color {
        switch verdict {
        case .all:
            return FlaccerColors.blue
        case .fake:
            return .red
        case .lossless:
            return FlaccerColors.green
        case .medium:
            return .yellow
        case .error:
            return .gray
        }
    }

    private func chipBackground(for verdict: SpectrumVerdict) -> Color {
        viewModel.filter == verdict ? chipAccent(for: verdict).opacity(0.18) : FlaccerColors.black
    }

    private enum FilterChipLabelStyle {
        case full
        case compact
    }
}

private struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? idealSingleLineWidth(for: subviews)
        return arrangement(for: subviews, maxWidth: max(maxWidth, 1)).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrangement(for: subviews, maxWidth: max(bounds.width, 1))
        for item in arrangement.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func idealSingleLineWidth(for subviews: Subviews) -> CGFloat {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let spacing = horizontalSpacing * CGFloat(max(subviews.count - 1, 0))
        return widths.reduce(0, +) + spacing
    }

    private func arrangement(for subviews: Subviews, maxWidth: CGFloat) -> (items: [WrappedItem], size: CGSize) {
        var items: [WrappedItem] = []
        var cursor = CGPoint.zero
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > maxWidth {
                cursor.x = 0
                cursor.y += lineHeight + verticalSpacing
                lineHeight = 0
            }

            items.append(WrappedItem(index: index, origin: cursor, size: size))
            usedWidth = max(usedWidth, cursor.x + size.width)
            cursor.x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        return (items, CGSize(width: usedWidth, height: cursor.y + lineHeight))
    }

    private struct WrappedItem {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }
}

private struct ResultCards: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if viewModel.filteredScanItems.isEmpty {
                    if viewModel.isPreparingScan {
                        PreparingResultIndicator(viewModel: viewModel, compact: false)
                    } else {
                        EmptyResultCard(filter: viewModel.filter)
                    }
                } else {
                    if viewModel.isPreparingScan {
                        PreparingResultIndicator(viewModel: viewModel, compact: true)
                        ResultRowDivider()
                    }
                    ForEach(viewModel.filteredScanSections) { section in
                        ResultGroupHeader(title: section.title, count: section.items.count)
                        ForEach(section.items) { item in
                            ResultCard(
                                item: item,
                                isFocused: item.result.map { result in
                                    viewModel.selectedResultID == result.id ||
                                        viewModel.selectedResultID == nil &&
                                        result.id == viewModel.filteredResults.first?.id
                                } ?? false,
                                focusAction: {
                                    if let result = item.result {
                                        viewModel.selectedResultID = result.id
                                    }
                                }
                            )
                            .contextMenu {
                                if let result = item.result {
                                    Button("Reveal in Finder") {
                                        viewModel.selectedResultID = result.id
                                        viewModel.revealInFinder([result])
                                    }
                                    Button("Copy Path") {
                                        viewModel.selectedResultID = result.id
                                        viewModel.copyPaths([result])
                                    }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) {
                                        viewModel.selectedResultID = result.id
                                        viewModel.requestMoveToTrash([result])
                                    }
                                }
                            }
                            if item.id != section.items.last?.id {
                                ResultRowDivider()
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 7)
            .padding(.bottom, 4)
        }
    }
}

private struct ResultGroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 8.5, weight: .bold))
        .foregroundStyle(FlaccerColors.textMuted)
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreparingResultIndicator: View {
    @ObservedObject var viewModel: FileScanViewModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(FlaccerColors.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing files")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))

                    Text("Finding supported tracks")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(FlaccerColors.textMuted)
                }

                Spacer(minLength: 0)
            }

            if viewModel.progressTotal > 0 {
                ProgressView(value: viewModel.progressFraction)
                    .tint(FlaccerColors.blue)
                    .controlSize(.small)
            }

        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 9 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 52 : 66, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ResultRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 10)
            .padding(.trailing, 8)
    }
}

private struct EmptyResultCard: View {
    let filter: SpectrumVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(filter == .all ? "No files yet" : "No \(filter.rawValue.lowercased()) files")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Drop audio files to start a local spectrum scan.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FlaccerColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(FlaccerColors.selection, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ResultCard: View {
    let item: ScanItem
    let isFocused: Bool
    let focusAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.82)
                    .multilineTextAlignment(.leading)

                Text(statusText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let result = item.result {
                VerdictBadge(verdict: result.verdict)
                    .scaleEffect(0.78)
            } else {
                PendingScanBadge(status: item.status)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(rowStroke, lineWidth: rowStrokeWidth)
        )
        .onTapGesture(perform: focusAction)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }

    private var statusText: String {
        if let result = item.result {
            return result.verdict == .error ? "Error" : "Done"
        }

        switch item.status {
        case .queued:
            return "Queued"
        case .analyzing:
            return "Analyzing"
        case .done:
            return "Done"
        }
    }

    private var rowBackground: Color {
        if isFocused {
            return FlaccerColors.sidebarSelection
        }
        if isHovering {
            return Color.white.opacity(0.045)
        }
        return .clear
    }

    private var rowStroke: Color {
        if isFocused {
            return FlaccerColors.sidebarSelection.opacity(0.35)
        }
        if isHovering {
            return Color.white.opacity(0.055)
        }
        return .clear
    }

    private var rowStrokeWidth: CGFloat {
        isFocused || isHovering ? 1 : 0
    }

    private var titleColor: Color {
        isFocused ? .white : Color.white.opacity(0.82)
    }

    private var subtitleColor: Color {
        isFocused ? Color.white.opacity(0.72) : FlaccerColors.textMuted
    }
}

private struct PendingScanBadge: View {
    let status: ScanItemStatus

    var body: some View {
        HStack(spacing: 6) {
            if status == .analyzing {
                ProgressView()
                    .controlSize(.small)
                    .tint(FlaccerColors.blue)
                    .scaleEffect(0.62)
            } else {
                Circle()
                    .fill(FlaccerColors.textMuted.opacity(0.55))
                    .frame(width: 6, height: 6)
            }

            Text(status == .analyzing ? "ANALYZING" : "QUEUED")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FlaccerColors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(FlaccerColors.black, in: Capsule(style: .continuous))
    }
}

private struct SidebarFooter: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: viewModel.isWatching ? "eye" : "eye.slash")
                Text(viewModel.watchFolder?.lastPathComponent ?? "No watch folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    viewModel.chooseWatchFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Choose watch folder")
            }

            if viewModel.progressTotal > 0 {
                ProgressView(value: viewModel.progressFraction)
                    .tint(FlaccerColors.blue)
                Text("\(viewModel.progressCompleted)/\(viewModel.progressTotal) - \(viewModel.currentActivity)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(viewModel.currentActivity)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(FlaccerColors.textMuted)
    }
}

private struct FlaccerDetailPane: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        ZStack {
            if let result = viewModel.selectedResult {
                DetailCard(viewModel: viewModel, result: result)
            } else {
                EmptyDetailCard(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyDetailCard: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isLoading ? "waveform" : "waveform.path.ecg.rectangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(FlaccerColors.green)
            Text(isLoading ? "Analyzing audio files" : "Drop audio to inspect its spectrum")
                .font(.system(size: 17, weight: .semibold))
            Text(isLoading ? "Finding tracks and streaming verdicts as they finish." : "Flaccer runs AVFoundation decoding and Accelerate FFT analysis entirely on this Mac.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlaccerColors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if isLoading {
                ProgressView(value: viewModel.progressTotal > 0 ? viewModel.progressFraction : nil)
                    .tint(FlaccerColors.blue)
                    .frame(width: 240)
            } else {
                Button {
                    viewModel.showOpenPanel()
                } label: {
                    Label("Choose Files or Folders", systemImage: "folder.badge.plus")
                }
                .controlSize(.regular)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(FlaccerColors.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var isLoading: Bool {
        viewModel.isPreparingScan || viewModel.isScanning
    }
}

private struct DetailCard: View {
    @ObservedObject var viewModel: FileScanViewModel
    let result: SpectrumResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailHeader(viewModel: viewModel, result: result)
            DiagnosisPanel(result: result)
                .frame(height: 132)
            SpectrogramView(result: result)
                .frame(minHeight: 220, idealHeight: 290, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlaccerColors.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .task(id: result.id) {
            viewModel.ensureSpectrogram(for: result, prewarmRaster: true)
        }
    }
}

private struct DetailHeader: View {
    @ObservedObject var viewModel: FileScanViewModel
    let result: SpectrumResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(result.fileName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.76)
                    .frame(height: 21, alignment: .leading)

                VerdictBadge(verdict: result.verdict)
                    .scaleEffect(0.82, anchor: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DetailActionStrip(viewModel: viewModel)
                .padding(.top, 1)
        }
        .frame(height: 48, alignment: .topLeading)
    }
}

private struct DiagnosisPanel: View {
    let result: SpectrumResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                MetricCard(title: "Verdict", value: result.verdict.rawValue, accent: verdictColor, monospaced: false)
                MetricCard(title: "Cutoff", value: result.cutoffText, accent: FlaccerColors.blue)
                MetricCard(title: "Confidence", value: confidenceText, accent: confidenceColor)
                MetricCard(title: "High Band", value: highBandText, accent: FlaccerColors.green)
                MetricCard(title: "Sample Rate", value: sampleRateText, accent: FlaccerColors.textSecondary)
                MetricCard(title: "Duration", value: durationText, accent: FlaccerColors.textSecondary)
            }

            Group {
                if let evidence = result.evidence {
                    EvidencePanel(result: result, evidence: evidence)
                } else if let summary {
                    SummaryEvidencePlaceholder(summary: summary)
                } else {
                    SummaryEvidencePlaceholder(summary: "")
                }
            }
            .frame(height: 78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verdictColor: Color {
        switch result.verdict {
        case .lossless:
            return FlaccerColors.green
        case .fake:
            return .red
        case .medium:
            return .yellow
        case .error:
            return .gray
        case .all:
            return FlaccerColors.blue
        }
    }

    private var confidenceText: String {
        guard result.verdict != .error else {
            return "n/a"
        }
        return "\(result.confidencePercent)%"
    }

    private var confidenceColor: Color {
        guard result.verdict != .error else {
            return .gray
        }
        if result.confidence >= 0.75 {
            return FlaccerColors.green
        }
        if result.confidence >= 0.55 {
            return .yellow
        }
        return .red
    }

    private var highBandText: String {
        guard result.verdict != .error else {
            return "n/a"
        }
        return Formatters.percent.string(from: NSNumber(value: result.highBandEnergy)) ?? "\(Int((result.highBandEnergy * 100).rounded()))%"
    }

    private var sampleRateText: String {
        guard result.sampleRate > 0 else {
            return "n/a"
        }
        return "\(String(format: "%.1f", result.sampleRate / 1_000)) kHz"
    }

    private var durationText: String {
        guard result.duration > 0 else {
            return "n/a"
        }
        let seconds = Int(result.duration.rounded())
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var summary: String? {
        if let error = result.errorMessage {
            return error
        }
        switch result.verdict {
        case .lossless:
            return "High-frequency energy remains visible near Nyquist."
        case .fake:
            return "Sharp high-frequency drop matches common lossy transcode behavior."
        case .medium:
            return "High-band profile is present but not decisive."
        case .error:
            return "The file could not be read as PCM audio."
        case .all:
            return nil
        }
    }
}

private struct SummaryEvidencePlaceholder: View {
    let summary: String

    var body: some View {
        Text(summary.isEmpty ? " " : summary)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(FlaccerColors.textSecondary)
            .lineLimit(2)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FlaccerColors.diagnosis.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct EvidencePanel: View {
    let result: SpectrumResult
    let evidence: SpectrumEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(primarySentence)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(height: 12, alignment: .leading)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112, maximum: 190), spacing: 5)],
                alignment: .leading,
                spacing: 5
            ) {
                EvidenceMetricRow(
                    title: "Brickwall",
                    value: dropText,
                    interpretation: brickwallInterpretation
                )
                EvidenceMetricRow(
                    title: "Upper Band",
                    value: upperBandText,
                    interpretation: upperBandInterpretation
                )
                EvidenceMetricRow(
                    title: "Cutoff Fit",
                    value: nyquistRatioText,
                    interpretation: scaledCutoffText
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.yellow.opacity(0.88))
                    .opacity(cautionText == nil ? 0 : 1)
                Text(cautionText ?? " ")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(FlaccerColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
            .frame(height: 12, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlaccerColors.diagnosis.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var primarySentence: String {
        switch result.verdict {
        case .lossless:
            return "Why: high-band energy remains visible close to Nyquist."
        case .fake:
            return "Why: a sharp high-frequency wall matches a likely transcode."
        case .medium:
            return "Why: the cutoff evidence is mixed, so inspect this one manually."
        case .error:
            return result.errorMessage ?? "The file could not be analyzed."
        case .all:
            return ""
        }
    }

    private var dropText: String {
        "\(String(format: "%.0f", evidence.brickwallDropDb)) dB"
    }

    private var brickwallInterpretation: String {
        if evidence.brickwallDropDb >= 22 {
            return "sharp drop"
        }
        if evidence.brickwallDropDb >= 15 {
            return "moderate drop"
        }
        return "no hard wall"
    }

    private var upperBandText: String {
        "\(String(format: "%+.0f", evidence.upperBandDeltaDb)) dB"
    }

    private var upperBandInterpretation: String {
        if evidence.upperBandEmpty {
            return "mostly empty"
        }
        if evidence.upperBandDeltaDb >= -8 {
            return "energy present"
        }
        return "partly reduced"
    }

    private var nyquistRatioText: String {
        "\(Int((evidence.cutoffToNyquistRatio * 100).rounded()))%"
    }

    private var scaledCutoffText: String {
        "scaled \(String(format: "%.1f", evidence.scaledCutoffKhz)) kHz"
    }

    private var cautionText: String? {
        if evidence.quietOrSparse {
            return "Caution: short, quiet, or sparse audio. Ref \(formatDb(evidence.referenceDb)), threshold \(formatDb(evidence.thresholdDb)), \(evidence.windowCount) windows."
        }
        if result.verdict == .medium {
            return "Caution: mixed evidence; inspect the cutoff region before acting on this result."
        }
        return nil
    }

    private func formatDb(_ value: Double) -> String {
        "\(String(format: "%.0f", value)) dB"
    }
}

private struct EvidenceMetricRow: View {
    let title: String
    let value: String
    let interpretation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FlaccerColors.textMuted)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Text(interpretation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(FlaccerColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let accent: Color
    var monospaced = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.92))
                    .frame(width: 16, height: 2.5)

                Text(title.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(FlaccerColors.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }

            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(FlaccerColors.diagnosis, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 0.75)
        )
    }
}

private struct DetailActionStrip: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.revealActionTargetsInFinder()
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 15)
            }
            .help("Reveal \(targetText) in Finder")

            Button {
                viewModel.copyActionTargetPaths()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 15)
            }
            .help("Copy \(targetText) path\(viewModel.actionTargetCount == 1 ? "" : "s")")

            Button {
                viewModel.exportActionTargetsCSV()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 15)
            }
            .help("Export \(targetText) CSV")

            Button(role: .destructive) {
                viewModel.requestMoveActionTargetsToTrash()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 15)
            }
            .help("Move \(targetText) to Trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .disabled(viewModel.actionTargetCount == 0)
    }

    private var targetText: String {
        viewModel.actionTargetCount == 1 ? "focused file" : "\(viewModel.actionTargetCount) filtered files"
    }
}

private enum FlaccerColors {
    static let window = Color(red: 0.11, green: 0.15, blue: 0.13)
    static let panel = Color(red: 0.015, green: 0.025, blue: 0.023)
    static let black = Color(red: 0.005, green: 0.010, blue: 0.010)
    static let drop = Color.black
    static let diagnosis = Color(red: 0.07, green: 0.07, blue: 0.065)
    static let selection = Color(red: 0.28, green: 0.28, blue: 0.28)
    static let sidebarSelection = Color(red: 0.02, green: 0.38, blue: 0.82)
    static let stroke = Color.white.opacity(0.16)
    static let textSecondary = Color.white.opacity(0.72)
    static let textMuted = Color.white.opacity(0.54)
    static let green = Color(red: 0.12, green: 0.84, blue: 0.32)
    static let blue = Color(red: 0.08, green: 0.56, blue: 1.0)
}
