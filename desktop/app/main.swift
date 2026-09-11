import AppKit
import WebKit

final class NetFleetApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var service: Process?
    private var endpoint: URL?
    private var token = ""
    private var startupBuffer = Data()
    private var stopping = false
    private var shutdownTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "NetFleet", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "saveBackup")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OPL NetFleet"
        window.minSize = NSSize(width: 860, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        showWindow()
        webView.loadHTMLString("<html><meta charset='utf-8'><body style='background:#f5f5f7;font:16px -apple-system;padding:60px;color:#202124'><h1>OPL NetFleet</h1><p>正在启动本机服务…</p></body></html>", baseURL: nil)
        startService()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 OPL NetFleet", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "显示 OPL NetFleet", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "隐藏 OPL NetFleet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出并恢复网络", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let navigationItem = NSMenuItem()
        let navigationMenu = NSMenu(title: "导航")
        for (index, entry) in [("概览", "overview"), ("出口", "exits"), ("机场", "providers"),
                                ("地区", "regions"), ("配置", "config"), ("诊断", "events")].enumerated() {
            let item = navigationMenu.addItem(withTitle: entry.0, action: #selector(pageCommand(_:)), keyEquivalent: String(index + 1))
            item.representedObject = entry.1
            item.target = self
        }
        navigationMenu.addItem(.separator())
        let refresh = navigationMenu.addItem(withTitle: "刷新状态", action: #selector(pageCommand(_:)), keyEquivalent: "r")
        refresh.representedObject = "refresh"
        refresh.target = self
        navigationItem.submenu = navigationMenu
        menu.addItem(navigationItem)
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "OPL NetFleet")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "显示 OPL NetFleet", action: #selector(showWindow), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出并恢复网络", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
    }

    @objc private func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let url = Bundle.main.url(forResource: "build", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let identity = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let commit = identity["source_commit"] as? String {
            let channel = identity["channel"] as? String == "local" ? "本地交付" : "开发构建"
            let dirty = identity["working_tree_dirty"] as? Bool == true ? " · 含未提交修改" : ""
            let arch = identity["build_target_arch"] as? String ?? ""
            options[.credits] = NSAttributedString(string: "\(channel) · \(arch)\(dirty)\n源码 \(commit.prefix(12))")
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func pageCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String,
              ["overview", "exits", "providers", "regions", "config", "events", "refresh"].contains(command) else { return }
        showWindow()
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('netfleet-command', {detail: '\(command)'}))", completionHandler: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func startService() {
        guard let resources = Bundle.main.resourceURL else { showError("应用资源目录缺失。请重新构建应用。"); return }
        let executable = resources.appendingPathComponent("runtime/bin/node")
        let script = resources.appendingPathComponent("desktop/runtime/server.mjs")
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: script.path) else {
            showError("应用运行组件不完整。请使用仓库的 macOS 构建入口重新生成应用。")
            return
        }
        let state = ProcessInfo.processInfo.environment["NETFLEET_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OPL NetFleet")
        let process = Process()
        process.executableURL = executable
        process.arguments = [script.path, "--state", state.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = resources.appendingPathComponent("runtime/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["NETFLEET_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["NETFLEET_RUNTIME_ROOT"] = resources.appendingPathComponent("runtime").path
        environment["NETFLEET_SOURCE_ROOT"] = resources.appendingPathComponent("shared").path
        process.environment = environment
        process.currentDirectoryURL = resources
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Backend errors may contain provider data. Never echo them into system logs.
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consumeStartup(data) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                if self.stopping {
                    self.shutdownTimer?.invalidate()
                    // Only a successful graceful exit proves cleanup completed.
                    NSApp.reply(toApplicationShouldTerminate: process.terminationStatus == 0)
                    if process.terminationStatus != 0 { self.stopping = false; self.showError("网络恢复未完成，应用保持打开。请检查诊断后重试退出。") }
                } else {
                    self.showError("本机服务已停止。请重新打开应用以读取并恢复上次网络状态。")
                }
            }
        }
        service = process
        do { try process.run() }
        catch { showError("无法启动本机服务：\(error.localizedDescription)") }
    }

    private func consumeStartup(_ data: Data) {
        guard endpoint == nil else { return }
        startupBuffer.append(data)
        guard startupBuffer.count < 65536 else { showError("本机服务未返回有效启动信息。"); return }
        while let end = startupBuffer.firstIndex(of: 10) {
            let line = startupBuffer.prefix(upTo: end)
            startupBuffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let text = object["url"] as? String, let url = URL(string: text),
                  url.scheme == "http", url.host == "127.0.0.1", let port = url.port, port > 0,
                  let secret = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value,
                  !secret.isEmpty else { continue }
            endpoint = URL(string: "http://127.0.0.1:\(port)")
            token = secret
            webView.load(URLRequest(url: url))
            return
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let service, service.isRunning else { return .terminateNow }
        if stopping { return .terminateCancel }
        guard let endpoint else { showError("服务仍在启动。请稍后使用“退出并恢复网络”。"); return .terminateCancel }
        stopping = true
        var request = URLRequest(url: endpoint.appendingPathComponent("api/action"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(endpoint.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"action\":\"shutdown\"}".utf8)
        request.timeoutInterval = 40
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.stopping else { return }
                if let data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true {
                    // The process termination callback confirms final cleanup.
                } else if self.service?.isRunning == true {
                    self.shutdownTimer?.invalidate()
                    self.stopping = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    self.showError("尚未确认网络已恢复，应用保持打开。请检查诊断后重试退出。")
                }
            }
        }.resume()
        shutdownTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            guard let self, self.stopping, self.service?.isRunning == true else { return }
            self.stopping = false
            NSApp.reply(toApplicationShouldTerminate: false)
            self.showError("服务尚未完成退出，应用保持打开。请检查诊断后重试。")
        }
        return .terminateLater
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" || (url.scheme == endpoint?.scheme && url.host == endpoint?.host && url.port == endpoint?.port) {
            decisionHandler(.allow)
        } else { decisionHandler(.cancel) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let endpoint, service?.isRunning == true, !stopping else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        if let url = components?.url { webView.load(URLRequest(url: url)) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "saveBackup", message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == endpoint?.port,
              let body = message.body as? [String: Any], let contents = body["contents"] as? String else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "netfleet-backup.json"
        panel.title = "保存 NetFleet 私有备份"
        panel.message = "备份包含订阅与配置，请保存到可信位置。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(contents.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { self?.showError("无法保存备份：\(error.localizedDescription)") }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "确认恢复配置"
        alert.informativeText = message
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    private func showError(_ message: String) {
        showWindow()
        let alert = NSAlert()
        alert.messageText = "OPL NetFleet"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
    }
}

let app = NSApplication.shared
let delegate = NetFleetApp()
app.delegate = delegate
app.run()
