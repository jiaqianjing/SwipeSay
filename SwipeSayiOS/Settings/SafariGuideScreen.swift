import SwiftUI

/// How to turn on the Safari extension. Apps can't open Safari's extension settings directly, so this walks the
/// user through it.
struct SafariGuideScreen: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("在网页上划词，就地出翻译", systemImage: "safari").font(.headline)
                    Text("打开 SwipeSay 的 Safari 扩展后，在网页上选中文字、稍停片刻，翻译或单词卡就会出现在选区下方，还能展开重点表达、继续追问。用的是你在 SwipeSay 里配置的模型服务和 Key。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("方法一：在系统设置里打开") {
                step(1, "打开「设置」› App ›「Safari 浏览器」›「扩展」（iOS 17 是「设置」›「Safari 浏览器」›「扩展」）。")
                step(2, "点「SwipeSay 划词翻译」，打开「允许扩展」。")
                step(3, "在「权限」里点「所有网站」，选「允许」。")
            }
            Section("方法二：在 Safari 里打开") {
                step(1, "在 Safari 里打开任意网页，点地址栏左侧的页面菜单按钮（「大小」或 ☰ 图标）。")
                step(2, "点「管理扩展」，打开「SwipeSay 划词翻译」。")
                step(3, "回到菜单，点 SwipeSay 图标 ›「始终允许」›「在所有网站上始终允许」。")
            }
            Section {
                step(1, "在网页菜单里点 SwipeSay 图标，可以改成「先显示『译』按钮」，或者暂停划词。")
                step(2, "第一次翻译时，面板里会先请你确认把文字发送给哪个模型服务。")
            } header: {
                Text("小提示")
            }
            Section {
                Button {
                    if let url = URL(string: "https://en.wikipedia.org/wiki/Second-language_acquisition") { openURL(url) }
                } label: {
                    Label("在 Safari 里试一试", systemImage: "arrow.up.forward.app")
                }
            } footer: {
                Text("SwipeSay 只读取你选中的文字和所在段落，不会读取或记录你浏览的其他内容。")
            }
        }
        .navigationTitle("Safari 划词翻译")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
