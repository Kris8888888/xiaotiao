import AppKit
import SwiftUI
import ServiceManagement
import Combine
import UserNotifications

final class AppState: ObservableObject {
    static let shared = AppState()

    let model = TickerModel()
    private(set) var overlay: Overlay!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var clockTimer: Timer?
    private var mouseMonitor: Any?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    @Published var lastError: String? = nil
    @Published var lastUpdate: Date? = nil
    @Published var visible = true
    /// 连续失败次数，用来自动退避：1 秒 → 3 秒 → 10 秒 → 30 秒，恢复后回到设定值
    private var failures = 0

    var settings: AppSettings {
        get { model.settings }
        set { model.settings = newValue; newValue.save(); settingsChanged() }
    }

    private var autoHidden = false          // 因为会议类应用到前台而自动藏起来的
    private var firedAlerts: Set<String> = []  // 已触发过的提醒键，价格回到区间内再重置

    private init() {
        model.settings = AppSettings.load()
        model.onTap = { [weak self] sym in self?.openQuotePage(sym) }
    }

    func start() {
        overlay = Overlay(model: model)
        setupStatusItem()
        registerHotKeys()
        applyLaunchAtLogin()
        startMouseMonitor()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.now = Date() }
        RunLoop.main.add(clockTimer!, forMode: .common)
        // 面板拖动结束后记位置
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: overlay.panel)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.savePosition() }.store(in: &cancellables)
        // 截图/演示用的环境变量，不写入设置
        let env = ProcessInfo.processInfo.environment
        if let d = env["XIAOTIAO_DEMO_DISGUISE"], let dis = Disguise(rawValue: d) { model.settings.disguise = dis }
        if env["XIAOTIAO_DEMO_SYMBOLS"] == "1" { var d = AppSettings(); d.positionX = model.settings.positionX; d.positionY = model.settings.positionY; model.settings = d }
        if let b = env["XIAOTIAO_DEMO_BACKDROP"], let bd = Backdrop(rawValue: b) { model.settings.backdrop = bd }
        if let m = env["XIAOTIAO_DEMO_MARK"], let mark = ChangeMark(rawValue: m) { model.settings.changeMark = mark }
        if env["XIAOTIAO_DEMO_SETTINGS"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openSettings() } }
        visible = !settings.hiddenOnLaunch
        if visible { showOverlay() }
        refresh()
        scheduleNext()
        startAppWatcher()
        startRightClick()
    }

    // MARK: 会议 / 投屏时自动隐藏

    private func startAppWatcher() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, self.settings.autoHideEnabled else { return }
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = (app?.localizedName ?? "") + " " + (app?.bundleIdentifier ?? "")
            let match = self.settings.autoHideApps.contains { !$0.isEmpty && name.localizedCaseInsensitiveContains($0) }
            if match, self.visible { self.hideOverlay(); self.autoHidden = true }
            else if !match, self.autoHidden { self.autoHidden = false; self.showOverlay() }
        }
    }

    // MARK: 小条上右键出菜单（不穿透时）

    private func startRightClick() {
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] e in
            guard let self = self, e.window === self.overlay.panel, let menu = self.statusItem.menu else { return e }
            NSMenu.popUpContextMenu(menu, with: e, for: self.overlay.panel.contentView!)
            return nil
        }
    }

    func openQuotePage(_ sym: Symbol) {
        if let u = sym.quotePageURL { NSWorkspace.shared.open(u) }
    }

    // MARK: 价格提醒

    private func checkAlerts(_ quotes: [String: Quote]) {
        for sym in settings.symbols {
            guard let q = quotes[sym.tencentKey] else { continue }
            let keyH = sym.tencentKey + "#H", keyL = sym.tencentKey + "#L"
            if let h = sym.alertHigh {
                if q.price >= h { if !firedAlerts.contains(keyH) { firedAlerts.insert(keyH); fireAlert(sym, q, text: "高于 \(fmt(h))") } }
                else { firedAlerts.remove(keyH) }
            }
            if let l = sym.alertLow {
                if q.price <= l { if !firedAlerts.contains(keyL) { firedAlerts.insert(keyL); fireAlert(sym, q, text: "低于 \(fmt(l))") } }
                else { firedAlerts.remove(keyL) }
            }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.\(settings.decimals)f", v) }

    private func fireAlert(_ sym: Symbol, _ q: Quote, text: String) {
        let name = sym.alias.isEmpty ? (sym.name.isEmpty ? sym.code : sym.name) : sym.alias
        model.alerting.insert(sym.tencentKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.model.alerting.remove(sym.tencentKey) }
        if settings.alertSound { NSSound(named: "Tink")?.play() }
        let content = UNMutableNotificationContent()
        content.title = "\(name) \(fmt(q.price))"
        content.body = "已\(text)，涨跌 \(String(format: "%+.2f%%", q.pct))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: 显示 / 隐藏

    func showOverlay() {
        let saved = (settings.positionX != nil && settings.positionY != nil) ? NSPoint(x: settings.positionX!, y: settings.positionY!) : nil
        overlay.show(at: saved)
        visible = true
        refreshMenu()
        scheduleNext()
    }

    func hideOverlay() { overlay.hide(); visible = false; refreshMenu(); scheduleNext() }
    func toggleOverlay() { visible ? hideOverlay() : showOverlay() }

    func toggleDisguise() {
        if settings.disguise == .none { return }
        model.revealed.toggle()
    }

    private func savePosition() {
        guard overlay.isVisible else { return }
        var s = model.settings
        s.positionX = overlay.topLeft.x; s.positionY = overlay.topLeft.y
        model.settings = s; s.save()
    }

    // MARK: 设置变更

    private func settingsChanged() {
        overlay.applyInteraction()
        registerHotKeys()
        applyLaunchAtLogin()
        refreshMenu()
        scheduleNext()
        refresh()
    }

    // MARK: 行情

    private var symbolsNeedingName: Bool { settings.symbols.contains { $0.name.isEmpty } }

    func refresh() {
        let syms = settings.symbols
        guard !syms.isEmpty else { return }
        QuoteService.shared.fetch(syms) { [weak self] quotes, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !quotes.isEmpty {
                    var merged = self.model.quotes
                    var changed: Set<String> = []
                    for (k, v) in quotes { if let old = merged[k], old.price != v.price { changed.insert(k) }; merged[k] = v }
                    self.model.quotes = merged
                    self.lastUpdate = Date(); self.model.lastUpdate = self.lastUpdate
                    if !changed.isEmpty, self.settings.flashOnChange {
                        self.model.flashing.formUnion(changed)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.model.flashing.subtract(changed) }
                    }
                    self.checkAlerts(quotes)
                    // 回填真名
                    if self.symbolsNeedingName {
                        var s = self.model.settings
                        for i in s.symbols.indices where s.symbols[i].name.isEmpty {
                            if let q = quotes[s.symbols[i].tencentKey] { s.symbols[i].name = q.name }
                        }
                        self.model.settings = s; s.save()
                    }
                }
                self.lastError = err
                self.failures = quotes.isEmpty ? self.failures + 1 : 0
                self.refreshMenu()
            }
        }
    }

    /// 当前应该多久刷一次
    private func currentInterval() -> Double {
        let fast = MarketHours.anyOpen(settings.symbols) && visible
        var interval = max(1, fast ? settings.fastInterval : settings.slowInterval)
        if failures > 0 {
            let backoff: Double = failures >= 6 ? 30 : (failures >= 3 ? 10 : 3)
            interval = max(interval, backoff)
        }
        return interval
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = currentInterval()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh(); self?.scheduleNext()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: 悬停探测（穿透状态下也能用）

    private var dragOffset: NSPoint? = nil

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.checkHover() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in self?.checkHover(); return e }
        // 穿透状态下：按住 ⌥ 在小条上拖动也能挪位置（全局监听，不用先解锁）
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self = self, self.settings.clickThrough, self.overlay.isVisible else { return }
            let loc = NSEvent.mouseLocation
            switch e.type {
            case .leftMouseDown:
                if e.modifierFlags.contains(.option), self.overlay.panel.frame.contains(loc) {
                    let f = self.overlay.panel.frame
                    self.dragOffset = NSPoint(x: loc.x - f.minX, y: loc.y - f.minY)
                }
            case .leftMouseDragged:
                if let off = self.dragOffset { self.overlay.panel.setFrameOrigin(NSPoint(x: loc.x - off.x, y: loc.y - off.y)) }
            case .leftMouseUp:
                if self.dragOffset != nil { self.dragOffset = nil; self.savePosition() }
            default: break
            }
        }
    }

    private var hoverRevealed = false
    private func checkHover() {
        guard settings.disguise != .none, settings.revealOnHover, overlay.isVisible else { return }
        let inside = overlay.panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if inside && !hoverRevealed { hoverRevealed = true; model.revealed = true }
        else if !inside && hoverRevealed { hoverRevealed = false; model.revealed = false }
    }

    // MARK: 快捷键

    private func registerHotKeys() {
        HotKeyCenter.shared.register(id: 1, preset: settings.toggleHotKey) { [weak self] in self?.toggleOverlay() }
        HotKeyCenter.shared.register(id: 2, preset: settings.disguiseHotKey) { [weak self] in self?.toggleDisguise() }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.toolTip = "小条"
        refreshMenu()
    }

    private func refreshMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        let statusText: String
        if let e = lastError { statusText = "行情获取失败（已放慢到 \(Int(currentInterval())) 秒）：" + e }
        else if let t = lastUpdate { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; statusText = "更新于 " + f.string(from: t) + (MarketHours.anyOpen(settings.symbols) ? "，交易中" : "，休市") }
        else { statusText = "正在获取行情…" }
        let st = NSMenuItem(title: statusText, action: nil, keyEquivalent: ""); st.isEnabled = false; menu.addItem(st)
        menu.addItem(.separator())
        menu.addItem(item(visible ? "隐藏小条" : "显示小条", #selector(menuToggle), hint: settings.toggleHotKey.label))
        let lock = item(settings.clickThrough ? "解除穿透（可直接拖动）" : "鼠标穿透（按住 ⌥ 仍可拖动）", #selector(menuToggleLock))
        menu.addItem(lock)
        let dis = NSMenuItem(title: "伪装", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for d in Disguise.allCases {
            let it = NSMenuItem(title: d.label, action: #selector(menuDisguise(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = d.rawValue; it.state = settings.disguise == d ? .on : .off; sub.addItem(it)
        }
        if settings.disguise != .none {
            sub.addItem(.separator())
            sub.addItem(item(model.revealed ? "收回" : "露出行情", #selector(menuReveal), hint: settings.disguiseHotKey.label))
        }
        dis.submenu = sub; menu.addItem(dis)
        menu.addItem(.separator())
        menu.addItem(item("立即刷新", #selector(menuRefresh)))
        menu.addItem(item("设置…", #selector(menuSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector, key: String = "", hint: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: hint.map { "\(title)　\($0)" } ?? title, action: sel, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    @objc private func menuToggle() { toggleOverlay() }
    @objc private func menuToggleLock() { var s = settings; s.clickThrough.toggle(); settings = s }
    @objc private func menuDisguise(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = Disguise(rawValue: raw) else { return }
        var s = settings; s.disguise = d; settings = s; model.revealed = false
    }
    @objc private func menuReveal() { toggleDisguise() }
    @objc private func menuRefresh() { refresh() }
    @objc func menuSettings() { openSettings() }

    // MARK: 设置窗口

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "小条设置"
            w.contentView = NSHostingView(rootView: SettingsView(state: self))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: 登录启动

    private func applyLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if settings.launchAtLogin, svc.status != .enabled { try svc.register() }
            if !settings.launchAtLogin, svc.status == .enabled { try svc.unregister() }
        } catch { }
    }
}

/// 菜单栏图标：一个不起眼的小圆角条
enum MenuBarIcon {
    static func make() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 7.25, width: 14, height: 3.5), xRadius: 1.75, yRadius: 1.75).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
