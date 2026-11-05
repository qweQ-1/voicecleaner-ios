import UIKit
import SwiftUI

/// App 入口。
///
/// 用纯 UIKit 的 `AppDelegate` 而不是 SwiftUI 的 `@main App`：
/// 后者在 CI 归档时会报「App bundle is missing its bundle executable」，
/// 纯 UIKit 方案在 GitHub Actions 上更稳。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIHostingController(rootView: ContentView())
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 后台时释放麦克风（iOS 不允许后台录音，除非声明了后台音频模式）
        NotificationCenter.default.post(name: .voiceCleanerShouldStop, object: nil)
    }
}

extension Notification.Name {
    static let voiceCleanerShouldStop = Notification.Name("com.qweq-1.voicecleaner.shouldStop")
}
