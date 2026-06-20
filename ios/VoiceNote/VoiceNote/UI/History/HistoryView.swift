import SwiftUI

struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    let onVisitTap: (UUID) -> Void
    let onBack: () -> Void

    // 内部 Detail 导航 (iOS 14 兼容)
    @State private var selectedDetailId: UUID?
    @State private var showDetail = false

    var body: some View {
        Group {
            if viewModel.records.isEmpty && !viewModel.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无记录")
                        .font(.headline)
                    Text(viewModel.searchQuery.isEmpty
                        ? "还没有任何记录"
                        : "未找到 \"\(viewModel.searchQuery)\" 的相关记录")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                List {
                    ForEach(viewModel.records) { visit in
                        RecordRow(record: visit)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedDetailId = visit.id
                                showDetail = true
                                onVisitTap(visit.id)
                            }
                            .modifier(SwipeActionsModifier {
                                viewModel.deleteRecord(id: visit.id)
                            })
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let visit = viewModel.records[index]
                            viewModel.deleteRecord(id: visit.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("返回", action: onBack)
            }
        }
        .modifier(SearchableModifier(
            searchQuery: $viewModel.searchQuery,
            onSubmit: { viewModel.search() },
            onChange: { viewModel.loadAll() }
        ))
        .onAppear { viewModel.loadAll() }
        .background(detailLink)
    }

    // MARK: - Detail 导航 (iOS 14: 隐藏 NavigationLink)

    @ViewBuilder
    private var detailLink: some View {
        if let id = selectedDetailId {
            NavigationLink(
                destination: DetailView(
                    viewModel: DetailViewModel(container: viewModel.container),
                    visitId: id,
                    onBack: { showDetail = false }
                )
                .navigationBarBackButtonHidden(true),
                isActive: $showDetail,
                label: { EmptyView() }
            )
        }
    }
}

// MARK: - 搜索: iOS 15+ searchable / iOS 14 自定义搜索栏

private struct SearchableModifier: ViewModifier {
    @Binding var searchQuery: String
    let onSubmit: () -> Void
    let onChange: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .searchable(text: $searchQuery, prompt: "输入关键词搜索")
                .onSubmit(of: .search) { onSubmit() }
                .onChange(of: searchQuery) { _ in
                    if searchQuery.isEmpty { onChange() }
                }
        } else {
            // iOS 14: 自定义搜索栏
            VStack(spacing: 0) {
                iOS14SearchBar(
                    searchQuery: $searchQuery,
                    onSubmit: onSubmit,
                    onChange: onChange
                )
                content
            }
        }
    }
}

private struct iOS14SearchBar: View {
    @Binding var searchQuery: String
    let onSubmit: () -> Void
    let onChange: () -> Void
    @State private var localText: String = ""

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)

                TextField("输入关键词搜索", text: $localText, onCommit: {
                    searchQuery = localText
                    onSubmit()
                })
                .font(.subheadline)
                .autocapitalization(.none)
                .disableAutocorrection(true)

                if !localText.isEmpty {
                    Button(action: {
                        localText = ""
                        searchQuery = ""
                        onChange()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(10)

            if !localText.isEmpty {
                Button("搜索") {
                    searchQuery = localText
                    onSubmit()
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear { localText = searchQuery }
        .onChange(of: localText) { newValue in
            searchQuery = newValue
            if newValue.isEmpty { onChange() }
        }
    }
}

// MARK: - iOS 15+ swipeActions / iOS 14 .onDelete 互补

private struct SwipeActionsModifier: ViewModifier {
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
        } else {
            content
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
                if !record.memo.isEmpty {
                    Text("· \(record.memo)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if record.summary != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
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
}
