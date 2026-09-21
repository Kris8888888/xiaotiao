import AppKit
import SwiftUI
import Combine

/// 浮窗内容的数据源
final class TickerModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var quotes: [String: Quote] = [:]
    @Published var revealed = false          // 伪装时临时露出
    @Published var now = Date()
    @Published var error: String? = nil
    @Published var flashing: Set<String> = []     // 价格刚变的股票，短暂轻闪
    @Published var alerting: Set<String> = []     // 刚触发价格提醒的股票，亮一下
    @Published var lastUpdate: Date? = nil
    var onTap: ((Symbol) -> Void)? = nil
}

/// 置顶、穿透、跨 Space 的浮窗
final class Overlay {
    let panel: NSPanel
    let model: TickerModel
    private var host: NSHostingView<TickerView>
    private var cancellables: Set<AnyCancellable> = []

    init(model: TickerModel) {
        self.model = model
        host = NSHostingView(rootView: TickerView(model: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = host
        panel.isExcludedFromWindowsMenu = true
        applyInteraction()
        // 内容变了就重算尺寸
        model.objectWillChange.receive(on: DispatchQueue.main).debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.fitToContent(); self?.applyInteraction() }
            .store(in: &cancellables)
    }

    func applyInteraction() {
        panel.ignoresMouseEvents = model.settings.clickThrough
        panel.isMovableByWindowBackground = !model.settings.clickThrough
        panel.hasShadow = model.settings.showShadow && model.settings.backdrop != .none
    }

    /// 按内容大小调整面板，锚定左上角不动
    func fitToContent() {
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        frame.size = size
        frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        panel.setFrame(frame, display: true)
    }

    func show(at saved: NSPoint?) {
        fitToContent()
        if let p = saved { panel.setFrameTopLeftPoint(clamp(p)) }
        else if let vf = NSScreen.main?.visibleFrame { panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - panel.frame.width - 16, y: vf.maxY - 8)) }
        panel.orderFrontRegardless()
    }

    private func clamp(_ topLeft: NSPoint) -> NSPoint {
        guard let vf = (NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main)?.visibleFrame else { return topLeft }
        return NSPoint(x: min(max(topLeft.x, vf.minX), vf.maxX - 40), y: min(max(topLeft.y, vf.minY + 20), vf.maxY))
    }

    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }
    var topLeft: NSPoint { NSPoint(x: panel.frame.minX, y: panel.frame.maxY) }
}

// MARK: 内容视图

struct TickerView: View {
    @ObservedObject var model: TickerModel
    var s: AppSettings { model.settings }

    var body: some View {
        content
            .padding(.horizontal, 12 * s.scale)
            .padding(.vertical, (s.layout == .row ? 7 : 8) * s.scale)
            .background(backdrop)
            .clipShape(RoundedRectangle(cornerRadius: s.cornerRadius * s.scale, style: .continuous))
            .overlay {
                if s.showBorder { RoundedRectangle(cornerRadius: s.cornerRadius * s.scale, style: .continuous).stroke(fg.opacity(0.18), lineWidth: 1) }
            }
            .shadow(color: s.backdrop == .none ? Color.black.opacity(0.55) : .clear, radius: 2, y: 1)
            .fixedSize()
    }

    @ViewBuilder var content: some View {
        if s.disguise == .clock && !model.revealed {
            clock
        } else if s.symbols.isEmpty {
            Text("在设置里添加股票").font(base(11)).foregroundStyle(fg.opacity(0.7))
        } else if s.layout == .row {
            HStack(spacing: 0) {
                ForEach(Array(s.symbols.enumerated()), id: \.element.id) { i, sym in
                    if i > 0 { Rectangle().fill(fg.opacity(0.22)).frame(width: 1, height: 13 * s.scale).padding(.horizontal, 10 * s.scale) }
                    item(sym)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4 * s.scale) {
                ForEach(s.symbols) { sym in item(sym) }
            }
        }
    }

    var clock: some View {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let w = DateFormatter(); w.locale = Locale(identifier: "zh_CN"); w.dateFormat = "EEE"
        return HStack(alignment: .firstTextBaseline, spacing: 6 * s.scale) {
            Text(f.string(from: model.now)).font(base(13, weight: .medium)).monospacedDigit()
            Text(w.string(from: model.now)).font(base(11)).foregroundStyle(fg.opacity(0.6))
        }
        .foregroundStyle(fg)
    }

    func item(_ sym: Symbol) -> some View {
        let q = model.quotes[sym.tencentKey]
        let digitsOnly = s.disguise == .digits && !model.revealed
        let up = (q?.change ?? 0) >= 0
        let closed = !MarketHours.isOpen(sym.market, at: model.now)
        let dim = s.dimWhenClosed && closed
        let flashing = model.flashing.contains(sym.tencentKey)
        let alerting = model.alerting.contains(sym.tencentKey)
        let stale = !closed && (model.lastUpdate.map { model.now.timeIntervalSince($0) > max(10, s.fastInterval * 4) } ?? false)
        return HStack(alignment: .firstTextBaseline, spacing: 5 * s.scale) {
            if !digitsOnly, s.nameMode != .none {
                let label = s.nameMode == .alias ? (sym.alias.isEmpty ? sym.code : sym.alias) : (sym.name.isEmpty ? (q?.name ?? sym.code) : sym.name)
                Text(label).font(base(11)).foregroundStyle(fg.opacity(0.62)).lineLimit(1)
            }
            Text(q.map { fmt($0.price) } ?? "—").font(base(13, weight: .medium)).monospacedDigit().foregroundStyle(alerting ? Ink.cinnabar : fg)
            if let q = q {
                HStack(spacing: 1) {
                    if !digitsOnly, s.mark == .arrow { Text(up ? "▲" : "▼").font(base(8)).baselineOffset(1.5 * s.scale) }
                    if s.showChangeAmount { Text(number(q.change, decimals: s.decimals, digitsOnly: digitsOnly)).font(base(11)).monospacedDigit() }
                    Text(digitsOnly ? String(format: "%.2f", q.pct) : number(q.pct, decimals: 2, digitsOnly: false) + "%")
                        .font(base(11)).monospacedDigit()
                }
                .foregroundStyle(changeColor(up))
            }
            if stale && !digitsOnly { Circle().stroke(fg.opacity(0.45), lineWidth: 1).frame(width: 5 * s.scale, height: 5 * s.scale).help("这只股票的数据有一会儿没更新了") }
        }
        .opacity(dim ? 0.55 : (flashing && s.flashOnChange ? 0.45 : 1))
        .animation(.easeOut(duration: 0.35), value: flashing)
        .animation(.easeInOut(duration: 0.6), value: alerting)
        .contentShape(Rectangle())
        .onTapGesture { if !s.clickThrough, s.clickOpensQuote { model.onTap?(sym) } }
        .help(tooltip(sym, q, closed: closed))
    }

    func tooltip(_ sym: Symbol, _ q: Quote?, closed: Bool) -> String {
        var lines = [sym.name.isEmpty ? (q?.name ?? sym.code) : sym.name + "  " + sym.market.label + sym.code]
        if let q = q {
            if let pc = q.prevClose { lines.append("昨收 " + fmt(pc)) }
            if let o = q.open { lines.append("今开 " + fmt(o)) }
            if let h = q.high, let l = q.low { lines.append("最高 " + fmt(h) + "  最低 " + fmt(l)) }
            let t = q.time
            if t.count == 14 { lines.append("行情时间 " + t.dropFirst(8).prefix(2) + ":" + t.dropFirst(10).prefix(2) + ":" + t.dropFirst(12)) }
            else if !t.isEmpty { lines.append("行情时间 " + t) }
        }
        lines.append(closed ? "休市" : "交易中")
        if !s.clickThrough, s.clickOpensQuote { lines.append("点击打开行情页") }
        return lines.joined(separator: "\n")
    }

    // MARK: 样式

    func base(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size * s.scale, weight: weight, design: s.font.design) }

    var fg: Color { s.backdrop == .light ? Ink.ink : Ink.warmWhite }

    func changeColor(_ up: Bool) -> Color {
        switch s.palette {
        case .mono: return fg.opacity(0.78)
        case .redUp: return up ? Ink.cinnabar : Ink.pine
        case .greenUp: return up ? Ink.pine : Ink.cinnabar
        }
    }

    @ViewBuilder var backdrop: some View {
        switch s.backdrop {
        case .dark: Color(red: 20/255, green: 22/255, blue: 26/255).opacity(s.opacity)
        case .light: Color(red: 246/255, green: 247/255, blue: 245/255).opacity(s.opacity)
        case .none: Color.clear
        }
    }

    func fmt(_ v: Double) -> String { String(format: "%.\(s.decimals)f", v) }

    /// 按「涨跌标记」设置格式化：箭头模式不带符号（箭头已表意），正负号模式带 +/−，不标模式只给数值
    func number(_ v: Double, decimals: Int, digitsOnly: Bool) -> String {
        let body = String(format: "%.\(decimals)f", abs(v))
        if digitsOnly { return String(format: "%.\(decimals)f", v) }
        switch s.mark {
        case .arrow: return body
        case .sign: return (v < 0 ? "−" : "+") + body
        case .none: return v < 0 ? "−" + body : body
        }
    }
}
