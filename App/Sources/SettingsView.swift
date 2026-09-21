import SwiftUI
import AppKit

/// 设置：改动即时生效
struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: TickerModel

    @State private var tab: Int = Int(ProcessInfo.processInfo.environment["XIAOTIAO_DEMO_TAB"] ?? "") ?? 0

    init(state: AppState) { self.state = state; self.model = state.model }

    var s: Binding<AppSettings> {
        Binding(get: { state.model.settings }, set: { state.settings = $0 })
    }

    var body: some View {
        TabView(selection: $tab) {
            StocksTab(state: state, s: s).tabItem { Label("股票", systemImage: "list.bullet") }.tag(0)
            LookTab(s: s).tabItem { Label("外观", systemImage: "paintbrush") }.tag(1)
            StealthTab(s: s).tabItem { Label("隐蔽", systemImage: "eye.slash") }.tag(2)
            GeneralTab(state: state, s: s).tabItem { Label("通用", systemImage: "gearshape") }.tag(3)
        }
        .padding(.top, 8)
        .frame(width: 640, height: 560)
    }
}

// MARK: 股票

struct StocksTab: View {
    @ObservedObject var state: AppState
    var s: Binding<AppSettings>
    @State private var input = ""
    @State private var message = ""
    @State private var checking = false
    @State private var suggestions: [QuoteService.Suggestion] = []
    @State private var searchTask: DispatchWorkItem? = nil

    var body: some View {
        Form {
            Section {
                if s.wrappedValue.symbols.isEmpty { Text("还没有股票。在下面输入代码添加。").foregroundStyle(.secondary) }
                List {
                    ForEach(s.symbols) { $sym in
                        HStack(spacing: 10) {
                            Text(sym.market.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.6)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sym.name.isEmpty ? sym.code : sym.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(sym.code).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(width: 128, alignment: .leading)
                            TextField("代号", text: $sym.alias, prompt: Text("代号")).textFieldStyle(.roundedBorder).frame(width: 64)
                            Text("提醒").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4)
                            OptionalNumberField(prompt: "高于", value: $sym.alertHigh).frame(width: 66)
                            OptionalNumberField(prompt: "低于", value: $sym.alertLow).frame(width: 66)
                            Spacer(minLength: 6)
                            if let q = state.model.quotes[sym.tencentKey] {
                                Text(String(format: "%.2f  %+.2f%%", q.price, q.pct)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                            }
                            Button { s.wrappedValue.symbols.removeAll { $0.id == sym.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in s.wrappedValue.symbols.move(fromOffsets: from, toOffset: to) }
                }
                .frame(minHeight: 200)
                HStack {
                    TextField("添加", text: $input, prompt: Text("代码或名字：600519、茅台、AAPL、apple")).textFieldStyle(.roundedBorder).onSubmit(add)
                        .onChange(of: input) { v in scheduleSearch(v) }
                    Button(checking ? "查询中…" : "添加", action: add).disabled(checking || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(suggestions) { sg in
                            Button { addSuggestion(sg) } label: {
                                HStack(spacing: 8) {
                                    Text(sg.symbol.market.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                                        .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.6)))
                                    Text(sg.symbol.name).font(.system(size: 13))
                                    Text(sg.symbol.code).font(.system(size: 12)).foregroundStyle(.secondary)
                                    Text(sg.typeName).font(.system(size: 11)).foregroundStyle(.tertiary)
                                    Spacer()
                                    Text("添加").font(.system(size: 12)).foregroundStyle(.blue)
                                }
                                .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(message.hasPrefix("已添加") ? .secondary : Color.red) }
            } header: { Text("自选股（拖动可排序）") } footer: {
                Text("填代码或者直接打名字都行：A 股 6 位数字自动判断沪深，美股字母代码；打「茅台」「apple」会出候选。「提醒」两格填价格，现价高于或低于它时通知你，留空不提醒。").font(.caption).foregroundStyle(.secondary)
            }
            Section("刷新") {
                Stepper("交易时段每 \(Int(s.wrappedValue.fastInterval)) 秒刷一次", value: s.fastInterval, in: 1...60)
                Stepper("休市时每 \(Int(s.wrappedValue.slowInterval)) 秒刷一次", value: s.slowInterval, in: 10...600, step: 10)
                Text("行情源本身每 3 秒更新一档，1 秒轮询是为了尽快拿到新的一档。接口连续失败时会自动放慢到 3 / 10 / 30 秒，恢复后回到这里设的值。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        // 纯代码就不搜；名字（含中文或 2 个字母以上）才搜
        guard !q.isEmpty, !(q.allSatisfy { $0.isNumber }), !(q.count <= 5 && q.allSatisfy { $0.isLetter } && q == q.uppercased()) else { suggestions = []; return }
        let task = DispatchWorkItem {
            QuoteService.shared.search(q) { list in DispatchQueue.main.async { if input.trimmingCharacters(in: .whitespaces) == q { suggestions = list } } }
        }
        searchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    func addSuggestion(_ sg: QuoteService.Suggestion) {
        var n = sg.symbol
        if s.wrappedValue.symbols.contains(where: { $0.market == n.market && $0.code == n.code }) { message = "已经在列表里了。"; suggestions = []; input = ""; return }
        n.alias = ""
        s.wrappedValue.symbols.append(n)
        message = "已添加 \(n.name)。"; suggestions = []; input = ""
        state.refresh()
    }

    func add() {
        let q = input.trimmingCharacters(in: .whitespaces)
        if Symbol.parse(q) == nil {
            // 是名字：有候选就加第一个，没有就现在搜一次再加
            if let first = suggestions.first { addSuggestion(first); return }
            checking = true; message = ""
            QuoteService.shared.search(q) { list in
                DispatchQueue.main.async {
                    checking = false
                    if let first = list.first { addSuggestion(first) } else { message = "没搜到「\(q)」，换个写法试试，或者直接填代码。" }
                }
            }
            return
        }
        guard let sym = Symbol.parse(q) else { return }
        if s.wrappedValue.symbols.contains(where: { $0.market == sym.market && $0.code == sym.code }) { message = "已经在列表里了。"; return }
        checking = true; message = ""
        QuoteService.shared.fetch([sym]) { quotes, err in
            DispatchQueue.main.async {
                checking = false
                if let q = quotes[sym.tencentKey] {
                    var n = sym; n.name = q.name
                    s.wrappedValue.symbols.append(n)
                    message = "已添加 \(q.name.isEmpty ? n.code : q.name)，现价 \(String(format: "%.2f", q.price))。"
                    input = ""; suggestions = []
                } else {
                    message = "没查到这个代码的行情" + (err.map { "：" + $0 } ?? "，请检查拼写。")
                }
            }
        }
    }
}

/// 可为空的数字输入框（价格提醒用）
struct OptionalNumberField: View {
    var prompt: String
    @Binding var value: Double?
    @State private var text: String = ""
    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).font(.system(size: 12)).multilineTextAlignment(.trailing)
            .onAppear { text = value.map { String(format: "%g", $0) } ?? "" }
            .onChange(of: text) { t in
                let trimmed = t.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { value = nil } else if let v = Double(trimmed) { value = v }
            }
            .onSubmit { if value != nil { AppState.shared.requestNotificationPermission() } }
    }
}

// MARK: 外观

struct LookTab: View {
    var s: Binding<AppSettings>
    var body: some View {
        Form {
            Section("大小与透明") {
                HStack { Text("大小"); Slider(value: s.scale, in: 0.7...2.0, step: 0.05); Text(String(format: "%.0f%%", s.wrappedValue.scale * 100)).frame(width: 44, alignment: .trailing).monospacedDigit() }
                HStack { Text("底色不透明度"); Slider(value: s.opacity, in: 0.2...1.0, step: 0.05).disabled(s.wrappedValue.backdrop == .none); Text(String(format: "%.0f%%", s.wrappedValue.opacity * 100)).frame(width: 44, alignment: .trailing).monospacedDigit() }
                HStack { Text("圆角"); Slider(value: s.cornerRadius, in: 0...16, step: 1); Text("\(Int(s.wrappedValue.cornerRadius))").frame(width: 44, alignment: .trailing).monospacedDigit() }
            }
            Section("样式") {
                Picker("底", selection: s.backdrop) { ForEach(Backdrop.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("涨跌颜色", selection: s.palette) { ForEach(Palette.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("字体", selection: s.font) { ForEach(FontStyle.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("排列", selection: s.layout) { ForEach(Layout.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Toggle("边框", isOn: s.showBorder)
                Toggle("阴影", isOn: s.showShadow)
            }
            Section("动态") {
                Toggle("价格变化时轻轻一闪", isOn: s.flashOnChange)
                Toggle("休市的市场变暗", isOn: s.dimWhenClosed)
                Toggle("不穿透时点击某只股票打开行情页", isOn: s.clickOpensQuote)
                Toggle("价格提醒时播放提示音", isOn: s.alertSound)
                Text("鼠标停在某只股票上会浮出昨收、今开、最高最低和行情时间。不穿透时在小条上右键可直接出菜单。").font(.caption).foregroundStyle(.secondary)
            }
            Section("显示什么") {
                Picker("名字", selection: s.nameMode) { ForEach(NameMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("涨跌标记", selection: Binding(get: { s.wrappedValue.mark }, set: { s.wrappedValue.changeMark = $0 })) {
                    ForEach(ChangeMark.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("涨跌额", isOn: s.showChangeAmount)
                Stepper("小数位：\(s.wrappedValue.decimals)", value: s.decimals, in: 0...4)
                Text("改动会立刻反映在浮窗上。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: 隐蔽

struct StealthTab: View {
    var s: Binding<AppSettings>
    var body: some View {
        Form {
            Section("鼠标") {
                Toggle("鼠标穿透（浮窗不吃点击，下面的窗口照常用）", isOn: s.clickThrough)
                Text("不穿透时直接按住小条拖动。开了穿透后，按住 Option（⌥）再拖也能挪位置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("伪装") {
                Picker("模式", selection: s.disguise) { ForEach(Disguise.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Text(s.wrappedValue.disguise.explain).font(.caption).foregroundStyle(.secondary)
                Toggle("鼠标停在浮窗上时露出行情", isOn: s.revealOnHover).disabled(s.wrappedValue.disguise == .none)
            }
            Section("快捷键（全局，任何应用里都能按）") {
                Picker("显示 / 隐藏浮窗", selection: s.toggleHotKey) { ForEach(HotKeyPreset.all) { Text($0.label).tag($0) } }
                Picker("露出 / 收回伪装", selection: s.disguiseHotKey) { ForEach(HotKeyPreset.all) { Text($0.label).tag($0) } }
                Text("两个快捷键别设成一样的。").font(.caption).foregroundStyle(.secondary)
            }
            Section("会议 / 投屏时自动隐藏") {
                Toggle("这些应用到前台时自动隐藏小条，切走后自动恢复", isOn: s.autoHideEnabled)
                AppNameList(list: s.autoHideApps).disabled(!s.wrappedValue.autoHideEnabled)
                Text("填应用名字的一部分即可，不分大小写。默认包含腾讯会议、Zoom、飞书会议、Keynote、Teams。").font(.caption).foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("打开应用时先不显示浮窗", isOn: s.hiddenOnLaunch)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppNameList: View {
    @Binding var list: [String]
    @State private var newName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list, id: \.self) { n in
                HStack { Text(n).font(.system(size: 12)); Spacer(); Button { list.removeAll { $0 == n } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            HStack {
                TextField("应用名", text: $newName, prompt: Text("例如：钉钉、QuickTime Player")).textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit(add)
                Button("添加", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
    func add() { let n = newName.trimmingCharacters(in: .whitespaces); if !n.isEmpty, !list.contains(n) { list.append(n) }; newName = "" }
}

// MARK: 通用

struct GeneralTab: View {
    @ObservedObject var state: AppState
    var s: Binding<AppSettings>
    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动打开", isOn: s.launchAtLogin)
                Text("应用只在菜单栏有一个小图标，不占 Dock。").font(.caption).foregroundStyle(.secondary)
            }
            Section("位置") {
                Button("把浮窗放回右上角") { var v = s.wrappedValue; v.positionX = nil; v.positionY = nil; state.settings = v; state.showOverlay() }
            }
            Section("数据") {
                Text("行情来自腾讯与东方财富的公开接口，直连不走代理，不需要账号。").font(.caption).foregroundStyle(.secondary)
                if let e = state.lastError { Text("最近一次错误：" + e).font(.caption).foregroundStyle(.red) }
            }
            Section("关于") {
                Text("小条 1.1。桌面隐蔽行情条。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
