import UIKit
import SwiftUI

/// SwiftUI 视图的 UIKit 宿主。
final class UIHostingController<Content: View>: UIHostingController<AnyView> {
    init(rootView: Content) {
        super.init(rootView: AnyView(rootView))
    }

    @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
