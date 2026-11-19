// Relays the content script's requests to the native handler (SafariWebExtensionHandler), which does the
// actual work with the user's own provider and key. Content scripts can't send native messages themselves.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || message.type !== "swipesay") return false;
    browser.runtime.sendNativeMessage("com.kenjia.swipesay.ios", message.payload)
        .then((reply) => sendResponse(reply || { ok: false, error: "SwipeSay 没有返回结果。" }))
        .catch((error) => sendResponse({ ok: false, error: "无法连接 SwipeSay：" + error }));
    return true;
});
