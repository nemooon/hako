import Foundation

struct CleanupResource: Identifiable {
    enum Kind: String { case image = "イメージ", cache = "ビルドキャッシュ" }
    let id: String
    let kind: Kind
    let name: String
    let bytes: Int64
    let reason: String
    let initiallySelected: Bool
}

struct CleanupScan {
    let context: String
    let builder: String?
    let resources: [CleanupResource]
    let warning: String?
}

struct CleanupResult {
    let name: String
    let success: Bool
    let detail: String
}

enum CleanupService {
    typealias Runner = ([String]) -> Shell.Result
    static func docker(_ arguments: [String]) -> Shell.Result {
        Shell.runProgram("/usr/bin/env", ["docker"] + arguments)
    }

    private static func output(_ args: [String], run: Runner) throws -> String {
        let result = run(args)
        guard result.status == 0 else {
            throw NSError(domain: "Cleanup", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey:
                result.stderr.isEmpty ? "Docker の情報を取得できませんでした。" : result.stderr])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func objects(_ text: String) throws -> [[String: Any]] {
        guard let data = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "Cleanup", code: -1, userInfo: [NSLocalizedDescriptionKey: "Docker の応答を読み取れませんでした。"])
        }
        return result
    }

    static func scan(run: Runner = docker) throws -> CleanupScan {
        let context = try output(["context", "show"], run: run)
        guard !context.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let prefix = ["--context", context]
        let containers = try output(prefix + ["ps", "-aq", "--no-trunc"], run: run).split(separator: "\n").map(String.init)
        var used = Set<String>()
        if !containers.isEmpty {
            let inspected = try objects(output(prefix + ["inspect"] + containers, run: run))
            // 不完全な応答では未使用と判定しない。
            guard inspected.count == containers.count, inspected.allSatisfy({ $0["Image"] is String }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            used = Set(inspected.compactMap { $0["Image"] as? String })
        }
        let ids = Set(try output(prefix + ["image", "ls", "-aq", "--no-trunc"], run: run).split(separator: "\n").map(String.init))
        var resources: [CleanupResource] = []
        if !ids.isEmpty {
            let images = try objects(output(prefix + ["image", "inspect"] + ids.sorted(), run: run))
            guard Set(images.compactMap { $0["Id"] as? String }) == ids else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for image in images {
                guard let id = image["Id"] as? String, let size = image["Size"] as? NSNumber else { throw CocoaError(.fileReadCorruptFile) }
                guard !used.contains(id) else { continue }
                let tags = (image["RepoTags"] as? [String] ?? []).filter { $0 != "<none>:<none>" }
                resources.append(CleanupResource(id: id, kind: .image,
                    name: tags.isEmpty ? "タグなし · \(id.prefix(19))" : tags.joined(separator: ", "),
                    bytes: size.int64Value, reason: "停止中を含むコンテナから参照なし", initiallySelected: tags.isEmpty))
            }
        }
        var builder: String?
        var warning: String?
        do {
            // コンテキストに対応する標準ビルダーに固定する。
            // 選択中の別ビルダー（リモートを含む）は対象にしない。
            let name = context
            let raw = try output(prefix + ["buildx", "du", "--builder", name, "--format=json"], run: run)
            var caches: [CleanupResource] = []
            for line in raw.split(separator: "\n") {
                let entries = try objects("[\(line)]")
                guard let entry = entries.first, let reclaimable = entry["Reclaimable"] as? Bool else { throw CocoaError(.fileReadCorruptFile) }
                guard reclaimable else { continue }
                guard let id = entry["ID"] as? String, !id.isEmpty,
                      let size = parseCacheSize(entry["Size"]) else {
                    throw NSError(domain: "Cleanup", code: -1, userInfo: [NSLocalizedDescriptionKey:
                        "Buildx のキャッシュIDまたは容量を読み取れませんでした（容量: \(entry["Size"] ?? "なし")）。"])
                }
                let lastUsedText = entry["LastUsedAt"] as? String
                let lastUsed = parseDate(lastUsedText)
                let shared = entry["Shared"] as? Bool == true
                let dateText = lastUsed.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) }
                    ?? lastUsedText.flatMap { $0.isEmpty ? nil : $0 } ?? "不明"
                caches.append(CleanupResource(id: id, kind: .cache,
                    name: entry["Description"] as? String ?? id, bytes: size,
                    reason: "最終使用: \(dateText)\(shared ? " · 共有データあり" : "")", initiallySelected: true))
            }
            builder = name
            resources += caches
        } catch {
            warning = "ビルドキャッシュを取得できませんでした。\n\(error.localizedDescription)"
        }
        return CleanupScan(context: context, builder: builder,
            resources: resources.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.id < $1.id
            }, warning: warning)
    }

    /// Buildx の JSON はバイト数と表示用文字列の両方が存在する。
    static func parseCacheSize(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        if let bytes = Int64(text) { return bytes >= 0 ? bytes : nil }
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*([kmgtp]?i?b)\*?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange]) else { return nil }
        let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15,
            "kib": 1024, "mib": 1048576, "gib": 1073741824, "tib": 1099511627776, "pib": 1125899906842624]
        guard let multiplier = units[text[unitRange].lowercased()] else { return nil }
        let bytes = (number * multiplier).rounded()
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func delete(_ resources: [CleanupResource], scan: CleanupScan, run: Runner = docker) -> [CleanupResult] {
        var results = resources.filter { $0.kind == .image }.map { resource in
            let prefix = ["--context", scan.context]
            let result: Shell.Result
            // 強制削除しない。スキャン後に参照された場合も Docker が拒否する。
            result = run(prefix + ["image", "rm", resource.id])
            let detail = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return CleanupResult(name: resource.name, success: result.status == 0,
                                 detail: detail.isEmpty ? "回収量の報告はありませんでした。" : detail)
        }
        let caches = resources.filter { $0.kind == .cache }
        guard !caches.isEmpty else { return results }
        let name = "ビルドキャッシュ \(caches.count) 件"
        guard let builder = scan.builder else {
            return results + [CleanupResult(name: name, success: false, detail: "対象ビルダーが不明です。再取得してください。")]
        }
        // 親子を別々に prune すると、先に処理した親が子への依存で残る。
        // 選択した ID の完全一致 OR を1つのフィルターにして一括処理する。
        let ids = caches.map(\.id).sorted()
        let pattern = "^(" + ids.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$"
        let prefix = ["--context", scan.context, "buildx"]
        let result = run(prefix + ["prune", "--builder", builder, "--all", "--force", "--filter", "id~=\(pattern)"])
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        do {
            let raw = try self.output(prefix + ["du", "--builder", builder, "--format=json"], run: run)
            let remaining = try Set(raw.split(separator: "\n").map { line -> String in
                guard let id = try objects("[\(line)]").first?["ID"] as? String else { throw CocoaError(.fileReadCorruptFile) }
                return id
            })
            let retained = caches.filter { remaining.contains($0.id) }
            let summary = "\(caches.count - retained.count) / \(caches.count) 件の削除を確認しました。"
            let detail = retained.isEmpty ? summary : summary + "\n使用中や依存関係により残った項目:\n" + retained.map { "\($0.name) (\($0.id))" }.joined(separator: "\n")
            results.append(CleanupResult(name: name, success: result.status == 0 && retained.isEmpty, detail: detail + "\n\n" + output))
        } catch {
            results.append(CleanupResult(name: name, success: false,
                detail: "削除結果を確認できませんでした。再取得して確認してください。\n\(error.localizedDescription)\n\n\(output)"))
        }
        return results
    }
}
