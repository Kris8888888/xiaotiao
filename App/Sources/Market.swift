import Foundation

/// 交易时段判断（不考虑节假日）
enum MarketHours {
    static func isOpen(_ m: Market, at now: Date = Date()) -> Bool {
        switch m {
        case .sh, .sz, .bj:
            return within(now, tz: "Asia/Shanghai", ranges: [(9 * 60 + 15, 11 * 60 + 30), (13 * 60, 15 * 60)])
        case .hk:
            return within(now, tz: "Asia/Hong_Kong", ranges: [(9 * 60 + 30, 12 * 60), (13 * 60, 16 * 60 + 10)])
        case .us:
            return within(now, tz: "America/New_York", ranges: [(9 * 60 + 30, 16 * 60)])
        }
    }

    private static func within(_ now: Date, tz: String, ranges: [(Int, Int)]) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        let wd = cal.component(.weekday, from: now)
        guard wd >= 2 && wd <= 6 else { return false }
        let m = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        return ranges.contains { m >= $0.0 && m <= $0.1 }
    }

    static func anyOpen(_ symbols: [Symbol]) -> Bool { symbols.contains { isOpen($0.market) } }
}
