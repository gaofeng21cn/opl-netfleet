import AppKit
import WebKit

// The AppKit host owns window chrome, the menu bar and the privileged bridge.
final class NetFleetApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSMenuItemValidation, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var dashboardWindow: NSWindow?
    private var dashboardWebView: WKWebView?
    private var statusItem: NSStatusItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var proxyMenu: NSMenu!
    private var statusMenu: NSMenu!
    private var service: Process?
    private var endpoint: URL?
    private var token = ""
    private var startupBuffer = Data()
    private var stopping = false
    private var shutdownTimer: Timer?
    // The page owns business state; the host only mirrors what it reports.
    private var pageState = PageState()

    // Everything the menu renders comes from the page. The host keeps no
    // business rules of its own: it shows this projection and sends the
    // user's choice back through the page's serialized action path.
    private struct HostRegion { var id: String; var name: String; var selected: Bool }
    private struct HostExit {
        var id: String; var name: String; var current: String; var detail: String
        var automatic: Bool; var selectable: Bool; var regions: [HostRegion]
    }
    private struct PageState {
        var running = false
        var configured = false
        var busy = false
        var mode = "unconfirmed"
        var networkMode = "explicit"
        var address = ""
        var summary = "代理已停止"
        var exits: [HostExit] = []
    }

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
        configuration.userContentController.add(self, name: "netfleetState")
        configuration.userContentController.add(self, name: "openDashboard")
        if let accent = hostAccentScript() {
            configuration.userContentController.addUserScript(WKUserScript(source: accent,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // The page paints its own sidebar and toolbar over the window backdrop.
        webView.underPageBackgroundColor = .clear
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "OPL NetFleet"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // The light window chrome keeps the page and the title bar the same tone in
        // every system appearance; the page owns the visual design.
        window.backgroundColor = NSColor(srgbRed: 0.961, green: 0.965, blue: 0.973, alpha: 1)
        // The minimum window size is part of the layout contract: it keeps the
        // content area at or above the 860x580 desktop layout budget so tables
        // never need horizontal scrolling and the page never reflows.
        window.minSize = NSSize(width: 1060, height: 640)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        let autosaveName = "OPLNetFleetMainWindow"
        let restored = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
        window.setFrameAutosaveName(autosaveName)
        if !restored { window.center() }
        showWindow()
        webView.loadHTMLString("<html><meta charset='utf-8'><body style='background:#f5f5f7;font:16px -apple-system;padding:60px;color:#202124'><h1>OPL NetFleet</h1><p>正在启动本机服务…</p></body></html>", baseURL: nil)
        startService()
    }

    // Hand the system accent to the page; the page derives its own tint ramp.
    private func hostAccentScript() -> String? {
        var resolved: NSColor?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        guard let color = resolved else { return nil }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return "window.__netfleetHostAccent = \"#\(String(format: "%02x%02x%02x", red, green, blue))\";"
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 OPL NetFleet", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "显示 OPL NetFleet", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "隐藏 OPL NetFleet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
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
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
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
        let proxyItem = NSMenuItem()
        proxyMenu = NSMenu(title: "代理")
        buildProxyItems(into: proxyMenu)
        proxyItem.submenu = proxyMenu
        menu.addItem(proxyItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = NSMenu()
        statusItem.menu = statusMenu
        buildStatusItems()
        updateStatusItem()
    }

    // The status item carries the whole quick workflow: state, start or stop,
    // the exits with their regions, the network takeover and the run mode.
    // Both the app menu and the status menu are rebuilt from the same page
    // projection so a choice can never reach a different code path.
    private func buildStatusItems() {
        statusMenu.removeAllItems()
        buildProxyItems(into: statusMenu)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "显示 OPL NetFleet", action: #selector(showWindow), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出并恢复网络", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    private func buildProxyItems(into menu: NSMenu) {
        menu.removeAllItems()
        let state = pageState
        let header = menu.addItem(withTitle: state.running
            ? (state.mode == "netfleet" ? "增强代理运行中 · \(state.summary)" : "原生代理运行中")
            : "代理已停止", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if state.running && !state.address.isEmpty {
            let detail = menu.addItem(withTitle: "\(state.address) · \(networkName(state.networkMode))", action: nil, keyEquivalent: "")
            detail.isEnabled = false
        }
        menu.addItem(.separator())
        startItem = menu.addItem(withTitle: "启动 NetFleet", action: #selector(startProxy(_:)), keyEquivalent: "")
        startItem.target = self
        startItem.isEnabled = !state.running && state.configured && !state.busy
        stopItem = menu.addItem(withTitle: "停止代理", action: #selector(stopProxy(_:)), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = state.running && !state.busy
        if !state.exits.isEmpty {
            menu.addItem(.separator())
            let root = menu.addItem(withTitle: "出口", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "出口")
            for exit in state.exits {
                let parent = submenu.addItem(withTitle: "\(exit.name) — \(exit.current) · \(exit.detail)", action: nil, keyEquivalent: "")
                let regions = NSMenu(title: exit.name)
                let automatic = regions.addItem(withTitle: "自动选优", action: #selector(pageMenuCommand(_:)), keyEquivalent: "")
                automatic.target = self
                automatic.state = exit.automatic ? .on : .off
                // Switching an exit needs a running NetFleet core; the page
                // refuses otherwise, so the menu says so instead of failing.
                automatic.isEnabled = exit.selectable && state.running && !state.busy
                automatic.representedObject = ["command": "select-auto", "capability": exit.id]
                if !exit.regions.isEmpty {
                    regions.addItem(.separator())
                    for region in exit.regions {
                        let item = regions.addItem(withTitle: region.name, action: #selector(pageMenuCommand(_:)), keyEquivalent: "")
                        item.target = self
                        item.state = region.selected ? .on : .off
                        item.isEnabled = state.running && !state.busy
                        item.representedObject = ["command": "select-region", "capability": exit.id, "region": region.id]
                    }
                }
                parent.submenu = regions
            }
            root.submenu = submenu
        }
        if state.configured {
            menu.addItem(.separator())
            let access = menu.addItem(withTitle: "网络接管", action: nil, keyEquivalent: "")
            let accessMenu = NSMenu(title: "网络接管")
            for (mode, title) in [("explicit", "仅显式代理"), ("system", "系统代理"), ("tun", "TUN 接管")] {
                let item = accessMenu.addItem(withTitle: title, action: #selector(pageMenuCommand(_:)), keyEquivalent: "")
                item.target = self
                item.state = state.networkMode == mode ? .on : .off
                item.representedObject = ["command": "network", "mode": mode]
                item.isEnabled = !state.busy
            }
            access.submenu = accessMenu
            let runMode = menu.addItem(withTitle: "运行模式", action: nil, keyEquivalent: "")
            let runMenu = NSMenu(title: "运行模式")
            for (mode, title) in [("netfleet", "增强模式（NetFleet 选优）"), ("mihomo", "原生配置")] {
                let item = runMenu.addItem(withTitle: title, action: #selector(pageMenuCommand(_:)), keyEquivalent: "")
                item.target = self
                item.state = state.mode == mode ? .on : .off
                item.representedObject = ["command": "mode", "mode": mode]
                item.isEnabled = !state.busy
            }
            runMode.submenu = runMenu
            menu.addItem(.separator())
            let reselect = menu.addItem(withTitle: "重新选优", action: #selector(pageMenuCommand(_:)), keyEquivalent: "")
            reselect.target = self
            reselect.representedObject = ["command": "reselect"]
            reselect.isEnabled = state.running && !state.busy
            let refresh = menu.addItem(withTitle: "刷新状态", action: #selector(pageMenuCommand(_:)), keyEquivalent: "")
            refresh.target = self
            refresh.representedObject = ["command": "refresh"]
            refresh.isEnabled = !state.busy
        }
    }

    private func networkName(_ mode: String) -> String {
        ["explicit": "仅显式代理", "system": "系统代理", "tun": "TUN 接管"][mode] ?? mode
    }

    @objc private func pageMenuCommand(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String] else { return }
        // Anything that still needs a decision happens in the page, so bring it
        // forward instead of acting invisibly from the menu bar.
        if payload["command"] != "refresh" { showWindow() }
        send(payload)
    }

    @objc private func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let url = Bundle.main.url(forResource: "build", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let identity = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let commit = identity["source_commit"] as? String {
            let channel = ["local": "本地交付", "distribution": "正式分发"][identity["channel"] as? String ?? ""] ?? "开发构建"
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
        send(command: command)
    }

    private func send(_ payload: Any) {
        guard endpoint != nil,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('netfleet-command', {detail: \(json)}))", completionHandler: nil)
    }

    private func send(command: String) {
        send(["command": command])
    }

    // Menu items mirror the page's reported state; the page remains the owner.
    private func updateStatusItem() {
        let running = pageState.running
        let detail = running
            ? (pageState.mode == "netfleet" ? " · \(pageState.summary)" : " · 原生配置") + " · \(networkName(pageState.networkMode))"
            : ""
        statusItem.button?.toolTip = "OPL NetFleet\(running ? " · 代理运行中" : " · 代理已停止")\(detail)"
        let symbol = running ? "network" : "network.slash"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OPL NetFleet")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "OPL NetFleet")
        buildProxyItems(into: proxyMenu)
        buildStatusItems()
    }

    @objc private func startProxy(_ sender: Any?) {
        showWindow()
        send(command: "start")
    }

    @objc private func stopProxy(_ sender: Any?) {
        showWindow()
        send(command: "stop")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startProxy(_:)): return !pageState.running && pageState.configured && !pageState.busy
        case #selector(stopProxy(_:)): return pageState.running && !pageState.busy
        case #selector(pageMenuCommand(_:)):
            // Menu items are rebuilt from page state; validation keeps them
            // honest if the state changes while the menu is open.
            guard let payload = menuItem.representedObject as? [String: String],
                  let command = payload["command"] else { return false }
            switch command {
            case "refresh": return !pageState.busy
            case "reselect": return pageState.running && !pageState.busy
            case "select-auto", "select-region": return pageState.running && !pageState.busy
            case "network", "mode": return pageState.configured && !pageState.busy
            default: return false
            }
        default: return true
        }
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
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == endpoint?.port else { return }
        if message.name == "netfleetState" {
            guard let body = message.body as? [String: Any],
                  let running = body["running"] as? Bool,
                  let configured = body["configured"] as? Bool,
                  let busy = body["busy"] as? Bool else { return }
            // Options are rebuilt from this projection; anything the page did
            // not report stays unavailable instead of being guessed here.
            pageState = PageState(
                running: running,
                configured: configured,
                busy: busy,
                mode: body["mode"] as? String ?? "unconfirmed",
                networkMode: body["networkMode"] as? String ?? "explicit",
                address: body["address"] as? String ?? "",
                summary: body["summary"] as? String ?? "代理已停止",
                exits: (body["exits"] as? [[String: Any]] ?? []).compactMap { value in
                    guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
                    return HostExit(
                        id: id,
                        name: name,
                        current: value["current"] as? String ?? "未接管",
                        detail: value["detail"] as? String ?? "未测量",
                        automatic: value["automatic"] as? Bool ?? false,
                        selectable: value["selectable"] as? Bool ?? false,
                        regions: (value["regions"] as? [[String: Any]] ?? []).compactMap { region in
                            guard let regionId = region["id"] as? String, let regionName = region["name"] as? String else { return nil }
                            return HostRegion(id: regionId, name: regionName, selected: region["selected"] as? Bool ?? false)
                        })
                })
            updateStatusItem()
            return
        }
        if message.name == "openDashboard" {
            showDashboard(message.body)
            return
        }
        guard message.name == "saveBackup", message.frameInfo.isMainFrame,
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

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === dashboardWindow else { return }
        dashboardWindow = nil
        dashboardWebView = nil
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

    // The complete Zashboard surface is a separate window, never a page inside
    // the business content area. It gets its own non-persistent web data store,
    // so the controller credential in the URL never reaches browser history or
    // a stored session, and closing the window drops it.
    private func showDashboard(_ body: Any) {
        guard let value = body as? [String: Any], let text = value["url"] as? String,
              let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, port >= 1024, port <= 65535, url.path == "/ui/" else {
            showError("面板地址无效，未打开。")
            return
        }
        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            dashboardWebView?.load(URLRequest(url: url))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = "Zashboard · OPL NetFleet"
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.delegate = self
        panel.center()
        dashboardWindow = panel
        dashboardWebView = view
        view.load(URLRequest(url: url))
        panel.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = NetFleetApp()
app.delegate = delegate
app.run()
