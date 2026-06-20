import SwiftUI

struct DetailView: View {
    @StateObject var viewModel: DetailViewModel
    let visitId: UUID
    let onBack: () -> Void

    @State private var showTranscript = false

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
    }

    private func content(_ visit: VoiceRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 基本信息
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

                // AI 总结
                if let summary = visit.summary {
                    GroupBox(label: Text("AI 总结")) {
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
                } else if visit.summaryStatus == .processing {
                    HStack {
                        ProgressView()
                        Text("正在生成总结...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if visit.summaryStatus == .unavailable {
                    VStack(spacing: 8) {
                        Text("总结生成失败")
                            .foregroundColor(.secondary)
                        Button {
                            viewModel.retrySummary()
                        } label: {
                            HStack {
                                if viewModel.isRetryingSummary {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                                Text(viewModel.isRetryingSummary ? "重试中..." : "重新生成")
                            }
                        }
                        .disabled(viewModel.isRetryingSummary)
                    }
                    .padding()
                }

                // 完整转写 — 显示文件名，点击查看内容
                if let transcript = visit.transcriptText, !transcript.isEmpty {
                    GroupBox(label: Text("完整转写")) {
                        Button {
                            showTranscript = true
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
                    .sheet(isPresented: $showTranscript) {
                        TranscriptSheetView(
                            title: transcriptFileName,
                            text: transcript,
                            onDismiss: { showTranscript = false }
                        )
                    }
                } else if visit.transcriptStatus == .processing {
                    HStack {
                        ProgressView()
                        Text("正在转写...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if visit.transcriptStatus == .unavailable {
                    VStack(spacing: 8) {
                        Text("转写失败")
                            .foregroundColor(.secondary)
                        Button {
                            viewModel.retryTranscript()
                        } label: {
                            HStack {
                                if viewModel.isRetryingTranscript {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                                Text(viewModel.isRetryingTranscript ? "重试中..." : "重新转写")
                            }
                        }
                        .disabled(viewModel.isRetryingTranscript)
                    }
                    .padding()
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
                    // 进度条
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { viewModel.audioPlayer.currentTime },
                                set: { viewModel.audioPlayer.seek(to: $0) }
                            ),
                            in: 0...max(viewModel.audioPlayer.duration, 0.01)
                        )
                        .accentColor(AppTheme.accentColor)

                        // 时间标签
                        HStack {
                            Text(viewModel.formatTime(viewModel.audioPlayer.currentTime))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(viewModel.formatTime(viewModel.audioPlayer.duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 播放控制按钮
                    HStack(spacing: 30) {
                        // 后退 15 秒
                        Button {
                            viewModel.audioPlayer.seek(
                                to: viewModel.audioPlayer.currentTime - 15
                            )
                        } label: {
                            Image(systemName: "gobackward")
                                .font(.title2)
                        }

                        // 播放/暂停
                        Button {
                            viewModel.audioPlayer.togglePlayPause()
                        } label: {
                            Image(systemName: viewModel.audioPlayer.isPlaying
                                  ? "pause.circle.fill"
                                  : "play.circle.fill"
                            )
                            .font(.system(size: 44))
                            .foregroundColor(AppTheme.accentColor)
                        }

                        // 前进 15 秒
                        Button {
                            viewModel.audioPlayer.seek(
                                to: viewModel.audioPlayer.currentTime + 15
                            )
                        } label: {
                            Image(systemName: "goforward")
                                .font(.title2)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("音频文件不可用")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - iOS 14 日期格式化 (Date.formatted() 仅 iOS 15+)

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

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
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "circle.fill")
                .font(.subheadline)
                .foregroundColor(color)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)")
                    .font(.subheadline)
                    .padding(.leading, 20)
            }
        }
    }

    // MARK: - 辅助

    /// 从 transcriptFilePath 提取文件名
    private var transcriptFileName: String {
        if let path = viewModel.visit?.transcriptFilePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "转写内容.txt"
    }
}

// MARK: - 转写全文弹窗

private struct TranscriptSheetView: View {
    let title: String
    let text: String
    let onDismiss: () -> Void

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
                        Button("关闭", action: onDismiss)
                    }
                }
            } else {
                // iOS 14: UITextView 自带滚动，不套 ScrollView
                SelectableTextView(text: text)
                    .padding()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("关闭", action: onDismiss)
                        }
                    }
            }
        }
    }
}

// MARK: - iOS 14 可选文本视图 (UITextView 包装)

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
