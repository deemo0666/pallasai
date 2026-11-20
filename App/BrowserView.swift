import SwiftUI
import WebKit

private enum ChatBrowserKey: EnvironmentKey {
    static let defaultValue: ((URL) -> Void)? = nil
}

extension EnvironmentValues {
    var showChatBrowser: ((URL) -> Void)? {
        get { self[ChatBrowserKey.self] }
        set { self[ChatBrowserKey.self] = newValue }
    }
}

#if os(macOS)
private struct BrowserSurface: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct BrowserSurface: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

struct BrowserView: View {
    let initialURL: URL?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var browser = BrowserTools.shared
    private var web: WKWebView { browser.web }
    @State private var address = ""
    @State private var url: URL?
    @State private var title = ""
    @State private var controls = false
    @State private var invalid = false
    @State private var back = false
    @State private var forward = false
    @State private var loading = false
    @State private var progress = 0.0
    @State private var started = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel("完成")
                Button {
                    controls.toggle()
                    if controls { address = url?.absoluteString ?? address } else { editing = false }
                } label: {
                    Text(title.isEmpty ? String(localized: "查看浏览器") : title)
                        .font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                }.accessibilityIdentifier("browserPageTitle").accessibilityHint("显示或收起地址栏和导航按钮")
            }.padding(.horizontal, 4).foregroundStyle(ChatColors.ink).buttonStyle(.plain)
            if controls {
                HStack {
                    TextField("网址", text: $address).focused($editing)
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled().submitLabel(.go).onSubmit(open)
                        .padding(.horizontal, 12).frame(minHeight: 40).background(ChatColors.chip, in: Capsule())
                    Button("打开", action: open).buttonStyle(.bordered)
                }.padding(.horizontal, 12).padding(.bottom, 8)
                if url != nil {
                    HStack(spacing: 20) {
                        Button { editing = false; web.goBack() } label: { Label("后退", systemImage: "chevron.backward") }.disabled(!back)
                        Button { editing = false; web.goForward() } label: { Label("前进", systemImage: "chevron.forward") }.disabled(!forward)
                        Spacer()
                        Button { if loading { web.stopLoading() } else { web.reload() } } label: {
                            Label(loading ? "停止加载" : "刷新", systemImage: loading ? "xmark" : "arrow.clockwise")
                        }
                        Button("收起") { editing = false; controls = false }
                    }.labelStyle(.iconOnly).padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            if let error = browser.loadError {
                Text(error).font(.callout).foregroundStyle(ChatColors.ink).padding(10)
            }
            if loading { ProgressView(value: progress).progressViewStyle(.linear) }
            BrowserSurface(web: web).opacity(url == nil && !loading ? 0 : 1)
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay {
                    if url == nil && !loading {
                        Text("还没有打开网页。模型调用浏览器工具后，这里会显示当前页面。")
                            .font(.body).foregroundStyle(ChatColors.ink).multilineTextAlignment(.center)
                            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("browserIdle")
                    }
                }
        }
        .background(ChatColors.adaptive(0xf9fafb, 0x1c2129).ignoresSafeArea())
        .onAppear {
            guard !started else { return }
            started = true
            web.allowsBackForwardNavigationGestures = true
            if let initialURL, BrowserRoute.accepts(initialURL), initialURL != web.url { web.load(URLRequest(url: initialURL)) }
        }
        .onReceive(web.publisher(for: \.url)) { value in url = value; if !editing { address = value?.absoluteString ?? "" } }
        .onReceive(web.publisher(for: \.title)) { title = $0 ?? "" }
        .onReceive(web.publisher(for: \.canGoBack)) { back = $0 }
        .onReceive(web.publisher(for: \.canGoForward)) { forward = $0 }
        .onReceive(web.publisher(for: \.isLoading)) { loading = $0 }
        .onReceive(web.publisher(for: \.estimatedProgress)) { progress = $0 }
        .alert("请输入有效的 HTTP 或 HTTPS 地址", isPresented: $invalid) { Button("好") {} }
    }

    private func open() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let target = URL(string: input.contains("://") ? input : "https://" + input),
              BrowserRoute.accepts(target) else { invalid = true; return }
        editing = false; controls = false
        web.load(URLRequest(url: target))
    }
}
