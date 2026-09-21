import SwiftUI

// MARK: 股票

enum Market: String, Codable { case sh, sz, bj, us, hk
    var label: String { switch self { case .sh: return "沪"; case .sz: return "深"; case .bj: return "北"; case .us: return "美"; case .hk: return "港" } }
}

struct Symbol: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var market: Market
    var code: String          // 600519 / AAPL
    var alias: String = ""    // 自己起的代号
    var name: String = ""     // 接口返回的真名
    var alertHigh: Double? = nil   // 高于此价提醒
    var alertLow: Double? = nil    // 低于此价提醒

    /// 腾讯接口用的代码：sh600519 / usAAPL
    var tencentKey: String { market.rawValue + code }

    /// 东方财富行情页
    var quotePageURL: URL? {
        switch market {
        case .sh, .sz, .bj: return URL(string: "https://quote.eastmoney.com/\(market.rawValue)\(code).html")
        case .us: return URL(string: "https://quote.eastmoney.com/us/\(code).html")
        case .hk: return URL(string: "https://quote.eastmoney.com/hk/\(code).html")
        }
    }

    /// 把用户输入变成 Symbol；认不出来返回 nil
    static func parse(_ raw: String) -> Symbol? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        for m in [Market.sh, .sz, .bj, .us, .hk] where lower.hasPrefix(m.rawValue) {
            let rest = String(s.dropFirst(2))
            guard !rest.isEmpty else { return nil }
            return Symbol(market: m, code: m == .us ? rest.uppercased() : rest)
        }
        if lower.hasSuffix(".ss") || lower.hasSuffix(".sh") { s = String(s.dropLast(3)); return Symbol(market: .sh, code: s) }
        if lower.hasSuffix(".sz") { s = String(s.dropLast(3)); return Symbol(market: .sz, code: s) }
        if s.allSatisfy({ $0.isNumber }) {
            if s.count == 5 { return Symbol(market: .hk, code: s) }
            guard s.count == 6, let first = s.first else { return nil }
            switch first {
            case "6", "9", "5": return Symbol(market: .sh, code: s)
            case "0", "3", "1", "2": return Symbol(market: .sz, code: s)
            case "4", "8": return Symbol(market: .bj, code: s)
            default: return nil
            }
        }
        // 只有 ASCII 字母才算美股代码；中文等其它文字是名字，交给搜索
        if s.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "." || $0 == "-") }) { return Symbol(market: .us, code: s.uppercased()) }
        return nil
    }
}

struct Quote: Equatable {
    var price: Double
    var change: Double
    var pct: Double
    var name: String
    var time: String
    var prevClose: Double? = nil
    var open: Double? = nil
    var high: Double? = nil
    var low: Double? = nil
    var updatedAt: Date = Date()
}

// MARK: 外观 / 隐蔽 / 设置

enum Palette: String, Codable, CaseIterable, Identifiable {
    case mono, redUp, greenUp
    var id: String { rawValue }
    var label: String { switch self { case .mono: return "单色"; case .redUp: return "红涨绿跌"; case .greenUp: return "绿涨红跌" } }
}

enum Backdrop: String, Codable, CaseIterable, Identifiable {
    case dark, light, none
    var id: String { rawValue }
    var label: String { switch self { case .dark: return "墨玻璃"; case .light: return "纸白"; case .none: return "无底" } }
}

enum FontStyle: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var label: String { switch self { case .system: return "系统"; case .rounded: return "圆体"; case .serif: return "衬线"; case .mono: return "等宽" } }
    var design: Font.Design { switch self { case .system: return .default; case .rounded: return .rounded; case .serif: return .serif; case .mono: return .monospaced } }
}

enum NameMode: String, Codable, CaseIterable, Identifiable {
    case none, alias, name
    var id: String { rawValue }
    var label: String { switch self { case .none: return "不显示"; case .alias: return "我的代号"; case .name: return "真名" } }
}

/// 涨跌怎么标
enum ChangeMark: String, Codable, CaseIterable, Identifiable {
    case arrow, sign, none
    var id: String { rawValue }
    var label: String { switch self { case .arrow: return "▲▼ 箭头"; case .sign: return "+ − 正负号"; case .none: return "不标" } }
}

enum Layout: String, Codable, CaseIterable, Identifiable {
    case row, column
    var id: String { rawValue }
    var label: String { self == .row ? "横条" : "竖列" }
}

enum Disguise: String, Codable, CaseIterable, Identifiable {
    case none, clock, digits
    var id: String { rawValue }
    var label: String { switch self { case .none: return "不伪装"; case .clock: return "时钟"; case .digits: return "纯数字" } }
    var explain: String {
        switch self {
        case .none: return "正常显示行情。"
        case .clock: return "只显示时间和星期。鼠标停在上面（或按露出快捷键）才显示行情。"
        case .digits: return "去掉名字、箭头和百分号，只剩一串数字，像随手记的数。"
        }
    }
}

/// 预设快捷键（避免做录制控件）
struct HotKeyPreset: Codable, Identifiable, Equatable, Hashable {
    var id: String { label }
    var label: String
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: controlKey 0x1000, optionKey 0x800, shiftKey 0x200, cmdKey 0x100

    static let none = HotKeyPreset(label: "不用快捷键", keyCode: 0, modifiers: 0)
    static let all: [HotKeyPreset] = [
        .none,
        HotKeyPreset(label: "⌃⌥S", keyCode: 1, modifiers: 0x1000 | 0x800),
        HotKeyPreset(label: "⌃⌥D", keyCode: 2, modifiers: 0x1000 | 0x800),
        HotKeyPreset(label: "⌃⌥H", keyCode: 4, modifiers: 0x1000 | 0x800),
        HotKeyPreset(label: "⌃⌥Z", keyCode: 6, modifiers: 0x1000 | 0x800),
        HotKeyPreset(label: "⌥空格", keyCode: 49, modifiers: 0x800),
        HotKeyPreset(label: "⌘⇧X", keyCode: 7, modifiers: 0x100 | 0x200),
        HotKeyPreset(label: "⌘⇧P", keyCode: 35, modifiers: 0x100 | 0x200),
        HotKeyPreset(label: "F19", keyCode: 80, modifiers: 0),
    ]
}

struct AppSettings: Codable, Equatable {
    var symbols: [Symbol] = [
        Symbol(market: .sh, code: "510300", alias: "300"),
        Symbol(market: .sh, code: "600519", alias: "MT"),
        Symbol(market: .us, code: "AAPL", alias: "A"),
    ]
    // 刷新
    var fastInterval: Double = 1
    var slowInterval: Double = 60
    // 外观
    var scale: Double = 1.0
    var opacity: Double = 0.85
    var backdrop: Backdrop = .dark
    var palette: Palette = .mono
    var font: FontStyle = .system
    var nameMode: NameMode = .alias
    var layout: Layout = .row
    var cornerRadius: Double = 9
    var showBorder: Bool = false
    var showShadow: Bool = true
    var showArrow: Bool = true            // 旧字段，保留兼容
    var changeMark: ChangeMark? = .arrow  // 新字段：箭头 / 正负号 / 不标
    var mark: ChangeMark { changeMark ?? (showArrow ? .arrow : .sign) }
    var showChangeAmount: Bool = false
    var decimals: Int = 2
    // 隐蔽
    var clickThrough: Bool = false
    var disguise: Disguise = .none
    var revealOnHover: Bool = true
    var toggleHotKey: HotKeyPreset = HotKeyPreset.all[1]   // ⌃⌥S
    var disguiseHotKey: HotKeyPreset = HotKeyPreset.all[2] // ⌃⌥D
    var hiddenOnLaunch: Bool = false
    // 体验
    var flashOnChange: Bool = true
    var dimWhenClosed: Bool = true
    var clickOpensQuote: Bool = true
    var alertSound: Bool = true
    var autoHideEnabled: Bool = true
    var autoHideApps: [String] = ["腾讯会议", "TencentMeeting", "zoom.us", "Zoom", "飞书会议", "Lark Meeting", "Keynote", "Microsoft Teams"]
    // 通用
    var launchAtLogin: Bool = false
    var positionX: Double? = nil
    var positionY: Double? = nil

    init() {}

    /// 兼容式解码：缺的字段用默认值，以后加字段不会重置已有设置
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        symbols = try c.decodeIfPresent([Symbol].self, forKey: .symbols) ?? d.symbols
        fastInterval = try c.decodeIfPresent(Double.self, forKey: .fastInterval) ?? d.fastInterval
        slowInterval = try c.decodeIfPresent(Double.self, forKey: .slowInterval) ?? d.slowInterval
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        backdrop = try c.decodeIfPresent(Backdrop.self, forKey: .backdrop) ?? d.backdrop
        palette = try c.decodeIfPresent(Palette.self, forKey: .palette) ?? d.palette
        font = try c.decodeIfPresent(FontStyle.self, forKey: .font) ?? d.font
        nameMode = try c.decodeIfPresent(NameMode.self, forKey: .nameMode) ?? d.nameMode
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? d.layout
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        showBorder = try c.decodeIfPresent(Bool.self, forKey: .showBorder) ?? d.showBorder
        showShadow = try c.decodeIfPresent(Bool.self, forKey: .showShadow) ?? d.showShadow
        showArrow = try c.decodeIfPresent(Bool.self, forKey: .showArrow) ?? d.showArrow
        changeMark = try c.decodeIfPresent(ChangeMark.self, forKey: .changeMark) ?? d.changeMark
        showChangeAmount = try c.decodeIfPresent(Bool.self, forKey: .showChangeAmount) ?? d.showChangeAmount
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals) ?? d.decimals
        clickThrough = try c.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? d.clickThrough
        disguise = try c.decodeIfPresent(Disguise.self, forKey: .disguise) ?? d.disguise
        revealOnHover = try c.decodeIfPresent(Bool.self, forKey: .revealOnHover) ?? d.revealOnHover
        toggleHotKey = try c.decodeIfPresent(HotKeyPreset.self, forKey: .toggleHotKey) ?? d.toggleHotKey
        disguiseHotKey = try c.decodeIfPresent(HotKeyPreset.self, forKey: .disguiseHotKey) ?? d.disguiseHotKey
        hiddenOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .hiddenOnLaunch) ?? d.hiddenOnLaunch
        flashOnChange = try c.decodeIfPresent(Bool.self, forKey: .flashOnChange) ?? d.flashOnChange
        dimWhenClosed = try c.decodeIfPresent(Bool.self, forKey: .dimWhenClosed) ?? d.dimWhenClosed
        clickOpensQuote = try c.decodeIfPresent(Bool.self, forKey: .clickOpensQuote) ?? d.clickOpensQuote
        alertSound = try c.decodeIfPresent(Bool.self, forKey: .alertSound) ?? d.alertSound
        autoHideEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoHideEnabled) ?? d.autoHideEnabled
        autoHideApps = try c.decodeIfPresent([String].self, forKey: .autoHideApps) ?? d.autoHideApps
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        positionX = try c.decodeIfPresent(Double.self, forKey: .positionX)
        positionY = try c.decodeIfPresent(Double.self, forKey: .positionY)
    }

    static let key = "settings.v2"
    static func load() -> AppSettings {
        if let d = UserDefaults.standard.data(forKey: key), var s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            if s.fastInterval == 3 { s.fastInterval = 1 }   // 旧默认值升级到 1 秒
            return s
        }
        return AppSettings()
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: AppSettings.key) } }
}

// MARK: 颜色

enum Ink {
    static let warmWhite = Color(red: 0xE8/255, green: 0xE6/255, blue: 0xE1/255)
    static let ink = Color(red: 0x1B/255, green: 0x24/255, blue: 0x30/255)
    static let cinnabar = Color(red: 0xC8/255, green: 0x55/255, blue: 0x3D/255)
    static let pine = Color(red: 0x4F/255, green: 0x8A/255, blue: 0x6B/255)
}
