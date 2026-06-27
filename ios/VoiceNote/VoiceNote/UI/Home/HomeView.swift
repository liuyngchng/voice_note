import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    let onNewVisit: () -> Void
    let onVisitTap: (UUID) -> Void

    @State private var isRefreshing = false

    var body: some View {
        List {
            Section(header: Text("今日概览")) {
                HStack {
                    StatCard(title: "今日记录", value: "\(viewModel.todayRecordCount)")
                    Spacer()
                    StatCard(title: "总记录", value: "\(viewModel.totalRecordCount)")
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("最近记录")) {
                if viewModel.recentRecords.isEmpty {
                    Text("暂无记录")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(viewModel.recentRecords) { record in
                        RecordRow(record: record)
                            .contentShape(Rectangle())
                            .onTapGesture { onVisitTap(record.id) }
                    }
                }
            }
        }
        .navigationTitle("语音笔记")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewVisit) {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear {
            viewModel.loadRecords()
        }
        .modifier(RefreshableModifier(isRefreshing: $isRefreshing) {
            viewModel.loadRecords()
        })
    }
}

// MARK: - 下拉刷新: iOS 15+ refreshable / iOS 14 UIRefreshControl

private struct RefreshableModifier: ViewModifier {
    @Binding var isRefreshing: Bool
    let onRefresh: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content.refreshable { onRefresh() }
        } else {
            content
                .background(PullToRefreshView(isRefreshing: $isRefreshing, onRefresh: onRefresh))
        }
    }
}

private struct PullToRefreshView: UIViewRepresentable {
    @Binding var isRefreshing: Bool
    let onRefresh: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let tableView = uiView.findParentTableView() else { return }
            context.coordinator.attach(to: tableView)
        }
        if let rc = context.coordinator.refreshControl {
            if isRefreshing && !rc.isRefreshing {
                rc.beginRefreshing()
            } else if !isRefreshing && rc.isRefreshing {
                rc.endRefreshing()
            }
        }
    }

    class Coordinator: NSObject {
        let parent: PullToRefreshView
        weak var refreshControl: UIRefreshControl?

        init(parent: PullToRefreshView) {
            self.parent = parent
        }

        func attach(to tableView: UITableView) {
            guard refreshControl == nil else { return }
            let rc = UIRefreshControl()
            rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
            tableView.refreshControl = rc
            refreshControl = rc
        }

        @objc func handleRefresh() {
            parent.isRefreshing = true
            parent.onRefresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.parent.isRefreshing = false
            }
        }
    }
}

private extension UIView {
    /// 安全查找父级 UITableView (非递归, 防栈溢出)
    func findParentTableView() -> UITableView? {
        var view: UIView? = self
        while let current = view {
            if let tableView = current as? UITableView { return tableView }
            for subview in current.subviews {
                if let tableView = subview as? UITableView { return tableView }
                for subsubview in subview.subviews {
                    if let tableView = subsubview as? UITableView { return tableView }
                }
            }
            view = current.superview
        }
        return nil
    }
}

// MARK: - 子组件

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title)
                .bold()
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct RecordRow: View {
    let record: VoiceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.title)
                    .font(.headline)
                Spacer()
                statusBadge
            }
            if !record.desc.isEmpty {
                Text(record.desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(record.startTime, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder var statusBadge: some View {
        if record.transcriptStatus == .completed {
            Text("已转写")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundColor(.green)
                .cornerRadius(4)
        } else if record.transcriptStatus == .processing {
            Text("处理中")
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .cornerRadius(4)
        }
    }
}
