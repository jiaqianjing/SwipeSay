import SafariServices
import SwipeSayKit

/// Native side of the Safari web extension. The content script sends requests through background.js
/// (`browser.runtime.sendNativeMessage`); each one arrives here, is answered by `WebBridge` and sent back.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let request = WebBridge.Request(message)
        Task { @MainActor in
            let reply = await WebBridge.handle(request)
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}
