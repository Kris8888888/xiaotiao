import CoreGraphics
import Foundation
// 打印指定进程名的所有窗口 id（按面积从大到小）
let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MailDigest"
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
var rows: [(Int, Double)] = []
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == target,
          let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
    rows.append((id, (b["Width"] ?? 0) * (b["Height"] ?? 0)))
}
for r in rows.sorted(by: { $0.1 > $1.1 }) { print(r.0) }
