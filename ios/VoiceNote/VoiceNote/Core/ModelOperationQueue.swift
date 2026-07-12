import Foundation

/// 串行操作队列 — 确保任意时刻只有一个模型操作（下载/导入/解压）在运行。
/// 参考 avatar/ios ModelManager.swift 的 OperationQueue actor 模式。
actor ModelOperationQueue {
    private var lastTask: Task<Void, Never>?
    /// 当前正在执行的操作 Task，用于 cancelCurrent() 精准取消
    private var currentOpTask: Task<Void, Never>?
    static let shared = ModelOperationQueue()

    func enqueue(_ operation: @escaping () async -> Void) {
        let prev = lastTask
        lastTask = Task { [weak self] in
            await prev?.value
            guard !Task.isCancelled else { return }
            let opTask = Task { await operation() }
            await self?.setCurrentOp(opTask)
            await opTask.value
            await self?.setCurrentOp(nil)
        }
    }

    private func setCurrentOp(_ task: Task<Void, Never>?) {
        currentOpTask = task
    }

    /// 取消当前正在执行的操作，重置队列链使得新任务无需等待已取消的任务。
    func cancelCurrent() {
        currentOpTask?.cancel()
        lastTask = nil
    }

    /// 取消所有操作，包括排队中的任务。
    func cancelAll() {
        currentOpTask?.cancel()
        lastTask?.cancel()
        lastTask = nil
    }
}
