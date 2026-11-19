# SwipeSay iOS / iPadOS：构建与上架清单

## 工程结构

| Target | 说明 | Bundle ID |
|---|---|---|
| `SwipeSay` | Mac 版，不变（Developer ID + Sparkle） | `com.kenjia.swipesay` |
| `SwipeSayiOS` | iPhone / iPad App | `com.kenjia.swipesay.ios` |
| `SwipeSayAction` | 分享菜单里的「SwipeSay 翻译」操作扩展 | `com.kenjia.swipesay.ios.action` |
| `SwipeSaySafari` | Safari 网页扩展「SwipeSay 划词翻译」：在网页上选中文字，翻译直接出现在选区下方 | `com.kenjia.swipesay.ios.safari` |

- 共用代码在本地 Swift 包 `Packages/SwipeSayKit`（提示词、模型服务、设置、缓存、用量、生词本），所有 target 都依赖它，对外的类型和方法标为 `public`。ChatGPT 订阅登录和快捷键模型在包里用 `#if os(macOS)` 包住，不会编进 iOS。界面层的 `Theme.swift`、`PopupViewModel.swift`、`ResultViews.swift`、`VocabularyView.swift` 仍以源文件形式编进 iOS target。
- 包有自己的单元测试：在 `Packages/SwipeSayKit` 目录运行 `swift test`。
- iOS 专用代码在 `SwipeSayiOS/`，App 和扩展共用的视图在 `SwipeSayiOS/Shared/`。
- Safari 扩展：`SwipeSaySafari/Resources/content.js` 负责监听选区、在页面里画面板（Shadow DOM，不受网页样式影响）；请求经 `background.js` 用 `sendNativeMessage` 发给 `SafariWebExtensionHandler`，由 `WebBridge.swift` 复用 `PopupViewModel` 完成翻译、单词卡、重点表达、追问和收藏（缓存、用量、自动加入生词本与 App 完全一致）。原生消息是一问一答，所以译文不是流式显示，而是一次性出现。
- Safari 扩展的工具栏弹窗（`popup.html`）可以选择划词后「直接弹出翻译」「先显示『译』按钮」或「暂停」。
- App 注册了 `swipesay://settings`，扩展在没有配置模型服务时用它跳回 App 的设置页。
- App 和扩展通过 App Group `group.com.kenjia.swipesay` 共享以下内容：设置（UserDefaults suite）、SwiftData 数据库（生词本、缓存、用量）、钥匙串里的 API Key。
- iOS 有自己的版本号：`project.yml` 里的 `SWIPESAY_IOS_VERSION` / `SWIPESAY_IOS_BUILD`。`scripts/release.sh` 只改 Mac 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，不会碰到 iOS 的版本号。
- 不允许 iPad 版在 Apple 芯片 Mac 上运行（`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO`），避免和 Mac 版冲突。

## 本地调试

```bash
xcodegen generate
```

```bash
xcodebuild -project SwipeSay.xcodeproj -scheme SwipeSayiOS -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

Debug 启动参数（只在 Debug 构建中生效）：

| 参数 | 作用 |
|---|---|
| `-SwipeSayMock YES` | 使用内置的假模型，不读写钥匙串，数据库只放在内存里。启动后会把这个开关同步给扩展 |
| `-SwipeSayDemo "<text>"` | 启动后立刻翻译这段文字 |
| `-SwipeSayDemoExpand YES` | 同时展开重点表达和句子解析 |
| `-SwipeSayDemoFollowUp "<question>"` | 翻译完成后自动追问 |
| `-SwipeSayDemoVocabulary YES` | 往生词本里填入示例词条 |
| `-SwipeSayTab vocabulary\|settings` | 启动时直接打开对应的标签页 |
| `-SwipeSayDemoBaseURL <url> -SwipeSayDemoConsent YES` | 显示 AI 数据共享同意页 |

## 上架前要在 Apple Developer / App Store Connect 里做的事

1. **Identifiers**：注册 App ID `com.kenjia.swipesay.ios` 和 `com.kenjia.swipesay.ios.action`，都勾选 App Groups，并注册 App Group `group.com.kenjia.swipesay`。用 Xcode 自动签名的话，第一次 Archive 时会自动完成这一步。
2. **App Store Connect 新建 App**：平台选 iOS，Bundle ID 选 `com.kenjia.swipesay.ios`，主要语言选简体中文。
3. **价格与销售范围**：**取消勾选「中国大陆」**。原因是大陆区的生成式 AI App 需要备案号，App 也需要 ICP 备案。
4. **欧盟 DSA**：声明是否为「商家」。如果声明为商家，姓名、地址、电话、邮箱会公开显示；不想公开的话，先不选欧盟区。
5. **隐私**
   - 隐私政策 URL：`https://github.com/jiaqianjing/SwipeSay/blob/main/docs/privacy.md`，合并到 main 后才能访问。
   - App 隐私标签：开发者不收集任何数据，可以选「不收集数据」。文字是在用户明确同意后，由设备直接发给用户自己选的服务，开发者收不到。
   - App 和扩展都已经带上 `PrivacyInfo.xcprivacy`（声明了 UserDefaults 的使用原因：CA92.1、1C8F.1）。
6. **年龄分级**：问卷里如实填写「AI 生成内容 / 开放式对话」（追问功能）。
7. **出口合规**：只用 HTTPS，`ITSAppUsesNonExemptEncryption = NO` 已经写进 Info.plist。
8. **截图**：6.9 寸 iPhone（如 iPhone 18 Pro Max）和 13 寸 iPad（iPad Pro 13-inch）两套。可以用上面的 Debug 参数，在模拟器里直接摆出需要的画面。
9. **App Review 备注**（必填，否则审核员会卡在「没有 API Key」这一步），模板：

   > SwipeSay is a bring-your-own-key translation and vocabulary app. It has no backend; text is sent directly from the device to the AI provider the user configures, after an explicit consent screen (guideline 5.1.2(i)).
   >
   > To test: Settings → OpenAI → paste the demo API key below → 设为当前使用. Then go to 翻译, type or paste English text and tap 翻译. A consent sheet names the provider and host before the first request.
   >
   > Safari extension: Settings → Apps → Safari → Extensions → SwipeSay 划词翻译 → turn on and allow on all websites. Then select text on any web page; the translation appears right below the selection. The first time, the panel asks for consent before sending anything.
   >
   > Share extension: select text in Safari or Notes → Share… → SwipeSay 翻译.
   >
   > Demo API key (OpenAI, spending-limited, for review only): `<填一个设了额度上限的 Key>`

   提审前要为审核单独建一个设了额度上限的 Key，审核通过后作废。

## 审核要点自查

- [x] 没有 ChatGPT 订阅登录（借用 Codex CLI 的 OAuth 客户端，只有 Mac 版保留）
- [x] 不包含 Sparkle，App 内也没有自更新
- [x] 每个服务（按服务 + 主机）第一次使用前弹出 AI 数据共享同意页，可以在 设置 › 隐私 里撤回
- [x] App 内能访问隐私政策
- [x] 粘贴使用 `PasteButton`，不会触发系统的「允许粘贴」弹窗
- [x] 支持 iPad 多任务（没有设置 `UIRequiresFullScreen`）
- [x] 局域网模型服务：`NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription`
- [x] Safari 扩展只申请 `nativeMessaging` 和 `storage` 权限；只读取选中的文字和所在段落，不记录浏览内容
- [x] Safari 扩展面板里有自己的同意页（服务名 + 主机），同意前不发送任何文字
- [ ] 真机测试：分享扩展（Safari 网页选词、备忘录）
- [ ] 真机测试：Safari 扩展（直接弹出 / 按钮模式、单词卡、重点表达、追问、收藏、同意页、未配置时跳回 App）
- [ ] 真机测试：首次添加 Key 后，扩展能读到钥匙串里的 Key（App Group 访问组）
- [ ] 在 App Review 备注里填写演示 Key

## 已知限制（第一期）

- 扩展写入生词本后，如果 App 一直在后台运行，生词本列表可能要等 App 重启才刷新（两个进程共用同一个 SwiftData 库，主 App 的 `@Query` 不会自动收到另一个进程的写入）。
- Safari 扩展的译文一次性出现，不像 App 里那样逐字流式显示。
- Safari 扩展在网页的输入框和可编辑区域里不触发，避免干扰打字。
- 还没有用量统计页、截图 OCR、快捷指令或小组件（都在后续计划里）。
- 生词本暂不和 Mac 同步（计划用 iCloud / CloudKit 实现，见 #22）。
