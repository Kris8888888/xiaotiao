import Foundation

/// 行情：腾讯为主，东方财富备用。都绕过系统代理直连。
final class QuoteService {
    static let shared = QuoteService()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]          // 国内行情站直连，不走 Clash
        c.timeoutIntervalForRequest = 5
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    func fetch(_ symbols: [Symbol], completion: @escaping ([String: Quote], String?) -> Void) {
        guard !symbols.isEmpty else { completion([:], nil); return }
        fetchTencent(symbols) { [weak self] quotes, err in
            if quotes.count >= symbols.count || err == nil && !quotes.isEmpty { completion(quotes, nil); return }
            // 主源不全或失败 → 备源补
            self?.fetchEastmoney(symbols) { q2, err2 in
                var merged = quotes
                for (k, v) in q2 where merged[k] == nil { merged[k] = v }
                completion(merged, merged.isEmpty ? (err ?? err2) : nil)
            }
        }
    }

    // MARK: 腾讯

    private func fetchTencent(_ symbols: [Symbol], completion: @escaping ([String: Quote], String?) -> Void) {
        let keys = symbols.map { $0.tencentKey }
        guard let url = URL(string: "https://qt.gtimg.cn/q=" + keys.joined(separator: ",")) else { completion([:], "地址无效"); return }
        session.dataTask(with: url) { data, _, err in
            if let err = err { completion([:], err.localizedDescription); return }
            guard let data = data else { completion([:], "没有数据"); return }
            let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) ?? String(decoding: data, as: UTF8.self)
            var out: [String: Quote] = [:]
            for line in text.components(separatedBy: ";") {
                // v_sh600519="1~贵州茅台~600519~1251.60~..."
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v_", with: "")
                let body = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r"))
                let f = body.components(separatedBy: "~")
                guard f.count > 34, let price = Double(f[3]), let change = Double(f[31]), let pct = Double(f[32]) else { continue }
                out[key] = Quote(price: price, change: change, pct: pct, name: f[1], time: f[30],
                                 prevClose: Double(f[4]), open: Double(f[5]), high: Double(f[33]), low: Double(f[34]))
            }
            completion(out, nil)
        }.resume()
    }

    // MARK: 按名字搜代码（东财）

    struct Suggestion: Identifiable, Equatable { var id: String { symbol.tencentKey }; var symbol: Symbol; var typeName: String }

    func search(_ text: String, completion: @escaping ([Suggestion]) -> Void) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://searchapi.eastmoney.com/api/suggest/get?input=\(enc)&type=14&token=D43BF722C8E33BDC906FB84D85E326E8&count=10") else { completion([]); return }
        session.dataTask(with: url) { data, _, _ in
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let table = json["QuotationCodeTable"] as? [String: Any], let rows = table["Data"] as? [[String: Any]] else { completion([]); return }
            var out: [Suggestion] = []
            for r in rows {
                guard let code = r["Code"] as? String, let name = r["Name"] as? String, let mk = r["MktNum"] as? String else { continue }
                let type = r["SecurityTypeName"] as? String ?? ""
                let market: Market?
                switch mk { case "1": market = .sh; case "0": market = .sz; case "105", "106", "107": market = .us; case "116": market = .hk; default: market = nil }
                guard let m = market else { continue }
                // 过滤掉债券、期权之类
                if type.contains("债") || type.contains("期权") || type.contains("Notes") || name.contains("Notes") { continue }
                var sym = Symbol(market: m, code: m == .us ? code.uppercased() : code); sym.name = name
                if !out.contains(where: { $0.symbol.tencentKey == sym.tencentKey }) { out.append(Suggestion(symbol: sym, typeName: type)) }
            }
            completion(Array(out.prefix(8)))
        }.resume()
    }

    // MARK: 东方财富

    private func secids(_ s: Symbol) -> [String] {
        switch s.market {
        case .sh: return ["1." + s.code]
        case .sz: return ["0." + s.code]
        case .bj: return ["0." + s.code]
        case .hk: return ["116." + s.code]
        case .us: return ["105.", "106.", "107."].map { $0 + s.code }
        }
    }

    private func fetchEastmoney(_ symbols: [Symbol], completion: @escaping ([String: Quote], String?) -> Void) {
        let ids = symbols.flatMap(secids).joined(separator: ",")
        guard let url = URL(string: "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&fields=f2,f3,f4,f12,f13,f14&secids=" + ids) else { completion([:], nil); return }
        session.dataTask(with: url) { data, _, err in
            if let err = err { completion([:], err.localizedDescription); return }
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = json["data"] as? [String: Any], let diff = d["diff"] as? [[String: Any]] else { completion([:], "备用源无数据"); return }
            var out: [String: Quote] = [:]
            for row in diff {
                guard let code = row["f12"] as? String, let mk = row["f13"] as? Int,
                      let price = row["f2"] as? Double, let pct = row["f3"] as? Double else { continue }
                let change = row["f4"] as? Double ?? 0
                let name = row["f14"] as? String ?? ""
                let market: Market = mk == 1 ? .sh : (mk == 0 ? .sz : (mk == 116 ? .hk : .us))
                let key = market.rawValue + code
                out[key] = Quote(price: price, change: change, pct: pct, name: name, time: "")
            }
            completion(out, nil)
        }.resume()
    }
}
