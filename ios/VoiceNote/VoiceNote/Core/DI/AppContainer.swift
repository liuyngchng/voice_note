import Foundation

/// 手动依赖注入容器
/// 对齐 Android: Hilt (AppModule.kt / DatabaseModule.kt / NetworkModule.kt)
@MainActor
final class AppContainer: ObservableObject {
    let audioCapture = AudioCapture()
    let asrClient = FunASRClient()
    let llmClient = LLMClient()
    let persistence = PersistenceController.shared

    lazy var recordRepository: RecordRepository = RecordRepositoryImpl(container: self)
    lazy var recordingManager = RecordingManager(container: self)

    init() {}
}
