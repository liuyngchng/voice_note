import SwiftUI

// MARK: - Sheet 类型 (iOS 14 仅支持单 sheet，用枚举统一)
private enum ActiveSheet: Identifiable {
    case transcript
    case share(URL)

    var id: String {
        switch self {
        case .transcript: return "transcript"
        case .share: return "share"
        }
    }
}

struct DetailView: View {
    @StateObject var viewModel: DetailViewModel
    let visitId: UUID
    let onBack: () -> Void

    @State private var selectedTab = 0
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("加载中...")
            } else if let visit = viewModel.visit {
                content(visit)
            } else {
                Text("记录不存在")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回", action: onBack)
            }
        }
        .onAppear { viewModel.loadRecord(id: visitId) }
        .onDisappear { viewModel.audioPlayer.stop() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .transcript:
                if let t = viewModel.visit?.transcriptText {
                    TranscriptSheetView(title: transcriptFileName, text: t)
                }
            case .share(let url):
                ActivitySheet(activityItems: [url])
            }
        }
    }

    private func content(_ visit: VoiceRecord) -> some View {
        VStack(spacing: 0) {
            // 选项卡
            Picker("", selection: $selectedTab) {
                Text("音频").tag(0)
                Text("转写").tag(1)
                Text("总结").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 内容区
            switch selectedTab {
            case 0: basicInfoTab(visit)
            case 1: transcriptTab(visit)
            case 2: summaryTab(visit)
            default: EmptyView()
            }
        }
    }

    // MARK: - 基本信息

    private func basicInfoTab(_ visit: VoiceRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Text("基本信息")) {
                    infoRow("标题", visit.title)
                    if !visit.memo.isEmpty {
                        infoRow("备注", visit.memo)
                    }
                    if !visit.desc.isEmpty {
                        infoRow("描述", visit.desc)
                    }
                    if !visit.speakers.isEmpty {
                        infoRow("参与人员", visit.speakers.joined(separator: "、"))
                    }
                    infoRow("开始时间", formattedDate(visit.startTime))
                    if let end = visit.endTime {
                        infoRow("结束时间", formattedDate(end))
                        infoRow("时长", AppTheme.formatDuration(end.timeIntervalSince(visit.startTime)))
                    }
                }

                // 录音回放
                if visit.audioFilePath != nil {
                    audioPlaybackSection
                }
            }
            .padding()
        }
    }

    // MARK: - 转写

    private func transcriptTab(_ visit: VoiceRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let transcript = visit.transcriptText, !transcript.isEmpty {
                    GroupBox(label: Text("完整转写")) {
                        Button {
                            activeSheet = nil
                            DispatchQueue.main.async { activeSheet = .transcript }
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(AppTheme.accentColor)
                                Text(transcriptFileName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                } else if visit.transcriptStatus == .processing {
                    HStack {
                        ProgressView()
                        Text("正在转写...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                } else if visit.transcriptStatus == .unavailable {
                    Text(viewModel.transcriptError ?? "转写失败")
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                } else if visit.transcriptStatus == .pending {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("转写准备中...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }

                // 手动重试入口（转写完成或失败后均可手动重试）
                if visit.transcriptStatus == .completed || visit.transcriptStatus == .unavailable {
                    Divider().padding(.horizontal)
                    HStack(spacing: 24) {
                        Button {
                            viewModel.retryTranscript()
                        } label: {
                            HStack(spacing: 4) {
                                if viewModel.isRetryingTranscript {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(viewModel.isRetryingTranscript ? "重试中..." : "重新转写")
                                    .font(.subheadline)
                            }
                        }
                        .disabled(viewModel.isRetryingTranscript)

                        if let path = visit.transcriptFilePath, !path.isEmpty,
                           FileManager.default.fileExists(atPath: path) {
                            Button {
                                let url = URL(fileURLWithPath: path)
                                activeSheet = nil
                                DispatchQueue.main.async { activeSheet = .share(url) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("导出")
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding()
        }
    }

    // MARK: - 总结

    private func summaryTab(_ visit: VoiceRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = visit.summary {
                    let isEmpty = summary.topics.isEmpty
                        && summary.conclusions.isEmpty
                        && summary.todos.isEmpty
                        && summary.nextSteps.isEmpty

                    if isEmpty {
                        Text("未能提取到有效总结内容\n转写文本可能过短或信息不足")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                            .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            if !summary.topics.isEmpty {
                                summarySection("议题", summary.topics, color: .blue)
                            }
                            if !summary.conclusions.isEmpty {
                                summarySection("结论", summary.conclusions, color: .green)
                            }
                            if !summary.todos.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("待办", systemImage: "list.bullet")
                                        .font(.subheadline)
                                        .foregroundColor(.orange)
                                    ForEach(summary.todos) { todo in
                                        HStack {
                                            Text("• \(todo.task)")
                                            if !todo.owner.isEmpty {
                                                Text("(\(todo.owner))")
                                                    .foregroundColor(.secondary)
                                                    .font(.caption)
                                            }
                                        }
                                    }
                                }
                            }
                            if !summary.nextSteps.isEmpty {
                                summarySection("后续", summary.nextSteps, color: .purple)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                    }

                    // 生成时间
                    if let generatedAt = visit.summaryGeneratedAt {
                        Text("生成于 \(formattedDateTime(generatedAt))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                } else if visit.summaryStatus == .processing {
                    HStack {
                        ProgressView()
                        Text("正在生成总结...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                } else if visit.summaryStatus == .unavailable {
                    Text(viewModel.summaryError ?? "总结生成失败")
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                } else if visit.summaryStatus == .pending {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("等待转写完成...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }

                // 手动重试入口（总结完成或失败后均可手动重试）
                if visit.summaryStatus == .completed || visit.summaryStatus == .unavailable {
                    Divider().padding(.horizontal)
                    Button {
                        viewModel.retrySummary()
                    } label: {
                        HStack {
                            if viewModel.isRetryingSummary {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(viewModel.isRetryingSummary ? "重试中..." : "重新总结")
                                .font(.subheadline)
                        }
                    }
                    .disabled(viewModel.isRetryingSummary)
                    .padding(.bottom, 8)
                }
            }
            .padding()
        }
    }

    // MARK: - 音频播放区域

    private var audioPlaybackSection: some View {
        GroupBox(label: Label("录音回放", systemImage: "waveform")) {
            VStack(spacing: 12) {
                if viewModel.audioPlayer.isReady {
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { viewModel.audioPlayer.currentTime },
                                set: { viewModel.audioPlayer.seek(to: $0) }
                            ),
                            in: 0...max(viewModel.audioPlayer.duration, 0.01)
                        )
                        .accentColor(AppTheme.accentColor)

                        HStack {
                            Text(viewModel.formatTime(viewModel.audioPlayer.currentTime))
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.formatTime(viewModel.audioPlayer.duration))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 30) {
                        Button {
                            viewModel.audioPlayer.seek(to: viewModel.audioPlayer.currentTime - 15)
                        } label: {
                            Image(systemName: "gobackward").font(.title2)
                        }

                        Button {
                            viewModel.audioPlayer.togglePlayPause()
                        } label: {
                            Image(systemName: viewModel.audioPlayer.isPlaying
                                  ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(AppTheme.accentColor)
                        }

                        Button {
                            viewModel.audioPlayer.seek(to: viewModel.audioPlayer.currentTime + 15)
                        } label: {
                            Image(systemName: "goforward").font(.title2)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                        Text("音频文件不可用").foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            // 导出音频
            if let path = viewModel.visit?.audioFilePath, FileManager.default.fileExists(atPath: path) {
                Divider()
                Button {
                    let url = URL(fileURLWithPath: path)
                    activeSheet = nil
                    DispatchQueue.main.async { activeSheet = .share(url) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 辅助视图

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.subheadline)
            Spacer()
        }
    }

    private func summarySection(_ title: String, _ items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                Text(title)
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.primary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 14, alignment: .leading)
                    Text(item)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formattedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter.string(from: date)
    }

    private var transcriptFileName: String {
        if let path = viewModel.visit?.transcriptFilePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "转写内容.txt"
    }
}

// MARK: - 分享面板 (UIActivityViewController, iOS 14 兼容)

private struct ActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiView: UIActivityViewController, context: Context) {}
}

// MARK: - 转写全文弹窗

private struct TranscriptSheetView: View {
    let title: String
    let text: String

    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            if #available(iOS 15.0, *) {
                ScrollView {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { presentationMode.wrappedValue.dismiss() }
                    }
                }
            } else {
                SelectableTextView(text: text)
                    .padding()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                        }
                    }
            }
        }
    }
}

// MARK: - iOS 14 可选文本视图

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.dataDetectorTypes = []
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = text
    }
}
