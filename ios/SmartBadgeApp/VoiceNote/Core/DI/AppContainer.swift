import Foundation

/// 手动依赖注入容器
/// 对齐 Android: Hilt (AppModule.kt / DatabaseModule.kt / NetworkModule.kt)
@MainActor
final class AppContainer: ObservableObject {
    let audioCapture = AudioCapture()
    let asrClient = FunASRClient()
    let llmClient = LLMClient()
    let locationTracker = LocationTracker()
    let persistence = PersistenceController.shared

    lazy var visitRepository: VisitRepository = VisitRepositoryImpl(container: self)

    init() {}
}
