import Foundation

struct PortMapping: Equatable {
    let host: String       // ホスト側ポート
    let container: String  // コンテナ側ポート

    var display: String { "\(host):\(container)" }
}

struct Container: Equatable {
    let id: String
    let name: String
    let image: String
    let state: String        // running / exited / paused など
    let status: String       // docker ps の Status 列("Up 4 minutes" など)
    var ports: [PortMapping] // ホスト側に公開する(している)ポート
    var startedAt: Date?
    var finishedAt: Date?
    let composeProject: String?
    let composeService: String?

    var isRunning: Bool { state == "running" }
    var hostPorts: [String] { ports.map(\.host) }

    /// レジストリのプレフィックスを除いたイメージ名(タグは残す)
    /// 例: "ghcr.io/nulab/backlog-mcp-server" → "backlog-mcp-server", "wordpress:php7.4" はそのまま
    var shortImage: String {
        image.split(separator: "/").last.map(String.init) ?? image
    }

    /// 「4分前に起動」「昨日に停止」のような表示用テキスト
    var friendlyStatus: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateTimeStyle = .named
        if isRunning, let startedAt {
            var text = "\(formatter.localizedString(for: startedAt, relativeTo: Date()))に起動"
            if status.contains("unhealthy") {
                text += " ・ unhealthy"
            }
            return text
        }
        if !isRunning, let finishedAt {
            return "\(formatter.localizedString(for: finishedAt, relativeTo: Date()))に停止"
        }
        return status // 時刻が取れなかったときは docker の表記のまま
    }

    /// status は毎分変わる文字列なので比較から外す(メニューの無駄な再構築を防ぐ)
    static func == (lhs: Container, rhs: Container) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.image == rhs.image
            && lhs.state == rhs.state
            && lhs.ports == rhs.ports
            && lhs.startedAt == rhs.startedAt
            && lhs.finishedAt == rhs.finishedAt
            && lhs.composeProject == rhs.composeProject
            && lhs.composeService == rhs.composeService
    }
}

struct ComposeProject: Equatable {
    let name: String
    let status: String       // 例: "running(3)", "exited(2)", "exited(1), running(3)"
    let configFiles: [String]

    var hasRunning: Bool { status.lowercased().contains("running") }
    var hasExited: Bool { status.lowercased().contains("exited") }

    /// config ファイルを指定して up -d するコマンド(相対パスの volume も compose 側で解決される)
    var upCommand: String {
        let files = configFiles.map { "-f '\($0)'" }.joined(separator: " ")
        return "docker compose -p '\(name)' \(files) up -d"
    }
}

struct ColimaSnapshot: Equatable {
    let running: Bool
    let vmInfo: String?      // 例: "CPU 2 ・ メモリ 12GB ・ ディスク 100GB"
    let containers: [Container]
    let composeProjects: [ComposeProject]
}

struct ContainerStats: Equatable {
    let cpu: String  // 例: "0.05%"
    let mem: String  // 例: "5.8MiB"
}

struct DiskUsage: Equatable {
    let type: String        // Images / Containers / Local Volumes / Build Cache
    let size: String        // 例: "3.2GB"
    let reclaimable: String // 例: "1.1GB (34%)"

    /// メニュー表示用の日本語ラベル
    var label: String {
        switch type {
        case "Images": return "イメージ"
        case "Containers": return "コンテナ"
        case "Local Volumes": return "ボリューム"
        case "Build Cache": return "ビルドキャッシュ"
        default: return type
        }
    }
}

enum ColimaService {
    /// Colima の状態と起動中コンテナをまとめて取得する(バックグラウンドキューで呼ぶこと)
    static func fetchSnapshot() -> ColimaSnapshot {
        let status = colimaStatus()
        guard status.running else {
            return ColimaSnapshot(running: false, vmInfo: nil, containers: [], composeProjects: [])
        }
        let snapshot = ColimaSnapshot(
            running: true,
            vmInfo: status.vmInfo,
            containers: listContainers(),
            composeProjects: listComposeProjects()
        )
        // HAKO_DEMO=1 で起動すると、スクリーンショット用に名前を架空のものへ置き換える
        if ProcessInfo.processInfo.environment["HAKO_DEMO"] != nil {
            return anonymize(snapshot)
        }
        return snapshot
    }

    // MARK: - デモモード

    private static let demoNames = ["acme-shop", "blog-stack", "chat-api", "photo-share", "recipe-box", "todo-app"]

    /// compose プロジェクト名(とそれを含むコンテナ名)を架空の名前に置き換える
    private static func anonymize(_ snapshot: ColimaSnapshot) -> ColimaSnapshot {
        let realNames = snapshot.composeProjects.map(\.name) + snapshot.containers.compactMap(\.composeProject)
        var mapping: [String: String] = [:]
        for (index, name) in Array(Set(realNames)).sorted().enumerated() {
            let suffix = index < demoNames.count ? "" : "-\(index / demoNames.count + 1)"
            mapping[name] = demoNames[index % demoNames.count] + suffix
        }

        func replace(_ text: String) -> String {
            mapping.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }

        return ColimaSnapshot(
            running: snapshot.running,
            vmInfo: snapshot.vmInfo,
            containers: snapshot.containers.map { c in
                Container(
                    id: c.id,
                    name: replace(c.name),
                    image: c.image,
                    state: c.state,
                    status: c.status,
                    ports: c.ports,
                    startedAt: c.startedAt,
                    finishedAt: c.finishedAt,
                    composeProject: c.composeProject.map { mapping[$0] ?? $0 },
                    composeService: c.composeService
                )
            },
            composeProjects: snapshot.composeProjects.map {
                ComposeProject(name: mapping[$0.name] ?? $0.name, status: $0.status, configFiles: $0.configFiles)
            }
        )
    }

    private static func colimaStatus() -> (running: Bool, vmInfo: String?) {
        // `colima ls --json` はプロファイルごとに 1 行の JSON を返す
        let result = Shell.run("colima ls --json")
        guard result.status == 0 else { return (false, nil) }

        for line in result.stdout.split(separator: "\n") {
            guard
                let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let status = json["status"] as? String
            else { continue }
            if status.lowercased() == "running" {
                var parts: [String] = []
                if let cpus = (json["cpus"] as? NSNumber)?.intValue {
                    parts.append("CPU \(cpus)")
                }
                if let memory = (json["memory"] as? NSNumber)?.int64Value, memory > 0 {
                    parts.append("メモリ \(memory / (1 << 30))GB")
                }
                if let disk = (json["disk"] as? NSNumber)?.int64Value, disk > 0 {
                    parts.append("ディスク \(disk / (1 << 30))GB")
                }
                return (true, parts.isEmpty ? nil : parts.joined(separator: " ・ "))
            }
        }
        return (false, nil)
    }

    /// 起動中コンテナの CPU / メモリ使用量(1 秒程度かかるのでスナップショットとは別に取る)
    static func fetchStats() -> [String: ContainerStats] {
        let result = Shell.run(#"docker stats --no-stream --format '{{json .}}'"#)
        guard result.status == 0 else { return [:] }

        var stats: [String: ContainerStats] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard
                let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = json["Container"] as? String
            else { continue }
            let memUsage = ((json["MemUsage"] as? String) ?? "")
                .components(separatedBy: " / ").first ?? ""
            // stats の ID はフル 64 桁なので、docker ps に合わせて 12 桁に詰める
            stats[String(id.prefix(12))] = ContainerStats(
                cpu: (json["CPUPerc"] as? String) ?? "",
                mem: memUsage
            )
        }
        return stats
    }

    /// ディスク使用量の内訳(docker system df は 1 秒近くかかるのでスナップショットとは別に取る)
    static func fetchDiskUsage() -> [DiskUsage] {
        let result = Shell.run(#"docker system df --format '{{json .}}'"#)
        guard result.status == 0 else { return [] }

        var usages: [DiskUsage] = []
        for line in result.stdout.split(separator: "\n") {
            guard
                let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = json["Type"] as? String
            else { continue }
            usages.append(DiskUsage(
                type: type,
                size: (json["Size"] as? String) ?? "",
                reclaimable: (json["Reclaimable"] as? String) ?? ""
            ))
        }
        return usages
    }

    private static func listContainers() -> [Container] {
        let result = Shell.run(#"docker ps -a --format '{{json .}}'"#)
        guard result.status == 0 else { return [] }

        var containers: [Container] = []
        for line in result.stdout.split(separator: "\n") {
            guard
                let data = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let labels = (json["Labels"] as? String) ?? ""
            func label(_ key: String) -> String? {
                labels.split(separator: ",")
                    .first { $0.hasPrefix("\(key)=") }
                    .map { String($0.dropFirst(key.count + 1)) }
            }
            let composeProject = label("com.docker.compose.project")
            let composeService = label("com.docker.compose.service")

            containers.append(Container(
                id: (json["ID"] as? String) ?? "",
                name: (json["Names"] as? String) ?? "(no name)",
                image: (json["Image"] as? String) ?? "",
                state: (json["State"] as? String) ?? "",
                status: (json["Status"] as? String) ?? "",
                ports: parsePortsColumn((json["Ports"] as? String) ?? ""),
                composeProject: composeProject,
                composeService: composeService
            ))
        }

        fillInspectDetails(&containers)
        return containers.sorted { $0.name < $1.name }
    }

    /// docker ps の Ports 列から公開ポートのペアを取り出す(IPv4/IPv6 の重複は除去)
    /// 例: "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 1025/tcp" → [8080:80]
    private static func parsePortsColumn(_ column: String) -> [PortMapping] {
        var seen = Set<String>()
        var result: [PortMapping] = []
        for entry in column.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let arrow = entry.range(of: "->") else { continue } // 未公開ポートはスキップ
            guard let hostPort = entry[..<arrow.lowerBound].split(separator: ":").last.map(String.init) else { continue }
            let containerPort = entry[arrow.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            let mapping = PortMapping(host: hostPort, container: containerPort)
            if seen.insert(mapping.display).inserted {
                result.append(mapping)
            }
        }
        return result
    }

    /// inspect で起動・停止時刻と、停止中コンテナの設定上のポート(Ports 列は空になる)を補完する
    private static func fillInspectDetails(_ containers: inout [Container]) {
        let ids = containers.map(\.id).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }

        let result = Shell.run(
            "docker inspect --format '{{.Id}}|{{.State.StartedAt}}|{{.State.FinishedAt}}|{{json .HostConfig.PortBindings}}' \(ids.joined(separator: " "))"
        )
        guard result.status == 0 else { return }

        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3)
            guard parts.count == 4 else { continue }

            let fullID = String(parts[0])
            guard let index = containers.firstIndex(where: { fullID.hasPrefix($0.id) }) else { continue }

            containers[index].startedAt = parseDockerDate(String(parts[1]))
            containers[index].finishedAt = parseDockerDate(String(parts[2]))

            if !containers[index].isRunning, containers[index].ports.isEmpty,
               let data = parts[3].data(using: .utf8),
               let bindings = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]] {
                var seen = Set<String>()
                containers[index].ports = bindings
                    .flatMap { key, values -> [PortMapping] in
                        // key は "80/tcp" のような「コンテナ側ポート/プロトコル」
                        let containerPort = key.split(separator: "/").first.map(String.init) ?? key
                        return values.compactMap { binding in
                            binding["HostPort"].map { PortMapping(host: $0, container: containerPort) }
                        }
                    }
                    .filter { seen.insert($0.display).inserted }
                    .sorted { (Int($0.host) ?? 0) < (Int($1.host) ?? 0) }
            }
        }
    }

    /// docker のナノ秒付き ISO8601("2026-07-06T14:45:58.123456789Z")をパースする
    /// 未起動・未停止を表す "0001-01-01T00:00:00Z" は nil にする
    private static func parseDockerDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            // ISO8601DateFormatter はナノ秒を扱えないので小数部を落とす(タイムゾーン部は残す)
            let zone = text[text.index(after: dot)...].drop { $0.isNumber }
            text = String(text[..<dot]) + zone
        }
        guard
            let date = ISO8601DateFormatter().date(from: text),
            date.timeIntervalSince1970 > 0
        else { return nil }
        return date
    }

    /// 停止中を含む compose プロジェクト一覧(down 済みでコンテナが無いものは出ない)
    private static func listComposeProjects() -> [ComposeProject] {
        let result = Shell.run("docker compose ls -a --format json")
        guard
            result.status == 0,
            let data = result.stdout.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return array.compactMap { json in
            guard let name = json["Name"] as? String else { return nil }
            let configFiles = ((json["ConfigFiles"] as? String) ?? "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            return ComposeProject(
                name: name,
                status: (json["Status"] as? String) ?? "",
                configFiles: configFiles
            )
        }
        .sorted { $0.name < $1.name }
    }
}
