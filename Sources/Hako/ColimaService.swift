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
    /// ヘルスチェックに失敗しているか(docker ps の Status 列に "(unhealthy)" が付く)
    var isUnhealthy: Bool { status.contains("unhealthy") }
    var hostPorts: [String] { ports.map(\.host) }

    /// レジストリのプレフィックスを除いたイメージ名(タグは残す)
    /// 例: "ghcr.io/nulab/backlog-mcp-server" → "backlog-mcp-server", "wordpress:php7.4" はそのまま
    var shortImage: String {
        image.split(separator: "/").last.map(String.init) ?? image
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// 「4分前に起動」「昨日に停止」のような表示用テキスト
    var friendlyStatus: String {
        let formatter = Self.relativeFormatter
        if isRunning, let startedAt {
            var text = "\(formatter.localizedString(for: startedAt, relativeTo: Date()))に起動"
            if isUnhealthy {
                text += " ・ unhealthy"
            }
            return text
        }
        if !isRunning, let finishedAt {
            return "\(formatter.localizedString(for: finishedAt, relativeTo: Date()))に停止"
        }
        return status // 時刻が取れなかったときは docker の表記のまま
    }

    /// compose プロジェクトなど、コンテナのまとまりとしての状態
    enum GroupState: Equatable {
        case stopped  // 1 つも動いていない
        case running  // 動いている(ポートを公開しない cli / init 用の停止は問題にしない)
        case partial  // 動いているのに、ポートを公開するはずのコンテナが止まっている
    }

    /// メニューバーのアイコン・メニューの丸印・メインウィンドウのサイドバーで共通の判定。
    /// ポートを公開しないコンテナ(バケット作成などの init 用、wp-cli など)は止まっていても数えない
    static func groupState(_ group: [Container]) -> GroupState {
        guard group.contains(where: \.isRunning) else { return .stopped }
        return group.contains { !$0.isRunning && !$0.ports.isEmpty } ? .partial : .running
    }

    /// 一覧の並び順: 起動中を先に、その中は名前順
    static func runningFirst(_ lhs: Container, _ rhs: Container) -> Bool {
        (lhs.isRunning ? 0 : 1, lhs.name) < (rhs.isRunning ? 0 : 1, rhs.name)
    }

    /// status は毎分変わる文字列なので比較から外す(メニューの無駄な再構築を防ぐ)。
    /// ただし unhealthy への変化は通知・表示に必要なので、その有無だけは比べる
    static func == (lhs: Container, rhs: Container) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.image == rhs.image
            && lhs.state == rhs.state
            && lhs.isUnhealthy == rhs.isUnhealthy
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

    /// config ファイルを指定して up -d する引数(相対パスの volume も compose 側で解決される)
    var upArguments: [String] {
        ["docker", "compose", "-p", name] + configFiles.flatMap { ["-f", $0] } + ["up", "-d"]
    }

    /// compose ファイルの置き場所(エディタで開くディレクトリ)
    var directory: String? {
        configFiles.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    }
}

struct ColimaSnapshot: Equatable {
    let profile: String      // 操作対象の colima プロファイル(docker の現在の context に対応)
    let running: Bool
    let vmInfo: String?      // 例: "CPU 2 ・ メモリ 12GB ・ ディスク 100GB"
    let containers: [Container]
    let composeProjects: [ComposeProject]
}

struct ContainerStats: Equatable {
    let cpu: String  // 例: "0.05%"
    let mem: String  // 例: "5.8MiB"

    var cpuPercent: Double? {
        Double(cpu.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    var memoryBytes: Double? {
        let value = mem.trimmingCharacters(in: .whitespaces)
        let number = value.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(number) else { return nil }
        let unit = value.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let multiplier = ByteUnit.multiplier(unit) else { return nil }
        return amount * multiplier
    }
}

/// docker / buildx が出す容量の単位(大文字小文字は区別しない)
enum ByteUnit {
    private static let multipliers: [String: Double] = [
        "b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15,
        "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824,
        "tib": 1_099_511_627_776, "pib": 1_125_899_906_842_624,
    ]

    static func multiplier(_ unit: some StringProtocol) -> Double? {
        multipliers[unit.lowercased()]
    }
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
        let profile = currentProfile()
        let status = colimaStatus(profile: profile)
        guard status.running else {
            return ColimaSnapshot(profile: profile, running: false, vmInfo: nil, containers: [], composeProjects: [])
        }
        // コンテナ一覧(ps → inspect)と compose 一覧は互いに依存しないので同時に取る
        var containers: [Container] = []
        var composeProjects: [ComposeProject] = []
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            composeProjects = listComposeProjects()
        }
        containers = listContainers()
        group.wait()
        let snapshot = ColimaSnapshot(
            profile: profile,
            running: true,
            vmInfo: status.vmInfo,
            containers: containers,
            composeProjects: composeProjects
        )
        // HAKO_DEMO=1 で起動すると、スクリーンショット用に名前を架空のものへ置き換える
        if ProcessInfo.processInfo.environment["HAKO_DEMO"] != nil {
            return anonymize(snapshot)
        }
        return snapshot
    }

    // MARK: - デモモード

    private static let demoNames = ["acme-shop", "blog-stack", "chat-api", "photo-share", "recipe-box", "todo-app"]

    /// スクリーンショットに出しても差し支えない、ありふれたサービス名。
    /// これ以外のサービス名は固有の情報(顧客名など)を含みうるので置き換える
    private static let genericServiceNames: Set<String> = [
        "app", "api", "web", "www", "worker", "batch", "cron", "proxy",
        "db", "database", "mysql", "mariadb", "postgres", "postgresql", "mongo", "mongodb",
        "redis", "memcached", "cache", "queue", "rabbitmq", "kafka",
        "nginx", "apache", "httpd", "php", "php-fpm", "wordpress",
        "mail", "mailhog", "mailpit", "smtp", "phpmyadmin", "adminer",
        "elasticsearch", "opensearch", "kibana", "minio", "localstack", "storage",
    ]

    /// compose のプロジェクト名・サービス名と、それらを含むコンテナ名・イメージ名を
    /// 架空のものに置き換える(サービス名はありふれたものだけ残す)
    private static func anonymize(_ snapshot: ColimaSnapshot) -> ColimaSnapshot {
        let realNames = snapshot.composeProjects.map(\.name) + snapshot.containers.compactMap(\.composeProject)
        var mapping: [String: String] = [:]
        for (index, name) in Array(Set(realNames)).sorted().enumerated() {
            let suffix = index < demoNames.count ? "" : "-\(index / demoNames.count + 1)"
            mapping[name] = demoNames[index % demoNames.count] + suffix
        }

        // ありふれた名前でないサービスは service-1, service-2… に置き換える
        let realServices = Set(snapshot.containers.compactMap(\.composeService))
            .filter { !genericServiceNames.contains($0.lowercased()) }
        for (index, name) in realServices.sorted().enumerated() {
            mapping[name] = "service-\(index + 1)"
        }

        // 「kidsnet-wordpress_gakken」のような複合名でも確実に消えるよう、長い名前から順に置換する
        let orderedMapping = mapping.sorted { $0.key.count > $1.key.count }
        func replace(_ text: String) -> String {
            orderedMapping.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }

        return ColimaSnapshot(
            profile: snapshot.profile,
            running: snapshot.running,
            vmInfo: snapshot.vmInfo,
            containers: snapshot.containers.map { c in
                Container(
                    id: c.id,
                    name: replace(c.name),
                    image: replace(c.image),
                    state: c.state,
                    status: c.status,
                    ports: c.ports,
                    startedAt: c.startedAt,
                    finishedAt: c.finishedAt,
                    composeProject: c.composeProject.map { mapping[$0] ?? $0 },
                    composeService: c.composeService.map { mapping[$0] ?? $0 }
                )
            },
            composeProjects: snapshot.composeProjects.map {
                ComposeProject(name: mapping[$0.name] ?? $0.name, status: $0.status, configFiles: $0.configFiles)
            }
        )
    }

    /// colima CLI 自体のバージョン(例: "0.9.1")。VM が停止していても取れる
    static func colimaVersion() -> String? {
        let result = Shell.exec(["colima", "version"])
        guard result.status == 0 else { return nil }
        // 1 行目の "colima version 0.9.1" から取り出す(以降の行は git commit や runtime 情報)
        for line in result.stdout.split(separator: "\n") where line.hasPrefix("colima version") {
            return line.split(separator: " ").last.map(String.init)
        }
        return nil
    }

    /// docker の現在の context に対応する colima プロファイル名。
    /// "colima" → "default"、"colima-work" → "work"。colima 以外の context なら "default"
    private static func currentProfile() -> String {
        let result = Shell.exec(["docker", "context", "show"])
        let context = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, context.hasPrefix("colima") else { return "default" }
        return context == "colima" ? "default" : String(context.dropFirst("colima-".count))
    }

    private static func colimaStatus(profile: String) -> (running: Bool, vmInfo: String?) {
        // `colima ls --json` はプロファイルごとに 1 行の JSON を返す
        let result = Shell.exec(["colima", "ls", "--json"])
        guard result.status == 0,
              let json = jsonLines(result.stdout).first(where: { $0["name"] as? String == profile }),
              (json["status"] as? String)?.lowercased() == "running"
        else { return (false, nil) }

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
        if profile != "default" {
            parts.insert("プロファイル \(profile)", at: 0)
        }
        return (true, parts.isEmpty ? nil : parts.joined(separator: " ・ "))
    }

    /// 1 行に 1 つの JSON オブジェクトが並ぶ出力(docker の --format '{{json .}}' など)を読む
    static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    /// 起動中コンテナの CPU / メモリ使用量(1 秒程度かかるのでスナップショットとは別に取る)
    static func fetchStats() -> [String: ContainerStats] {
        let result = Shell.exec(["docker", "stats", "--no-stream", "--format", "{{json .}}"])
        guard result.status == 0 else { return [:] }

        var stats: [String: ContainerStats] = [:]
        for json in jsonLines(result.stdout) {
            guard let id = json["Container"] as? String else { continue }
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
        let result = Shell.exec(["docker", "system", "df", "--format", "{{json .}}"])
        guard result.status == 0 else { return [] }

        return jsonLines(result.stdout).compactMap { json in
            guard let type = json["Type"] as? String else { return nil }
            return DiskUsage(
                type: type,
                size: (json["Size"] as? String) ?? "",
                reclaimable: (json["Reclaimable"] as? String) ?? ""
            )
        }
    }

    private static func listContainers() -> [Container] {
        let result = Shell.exec(["docker", "ps", "-a", "--format", "{{json .}}"])
        guard result.status == 0 else { return [] }

        var containers: [Container] = []
        for json in jsonLines(result.stdout) {

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

        let result = Shell.exec(
            ["docker", "inspect", "--format",
             "{{.Id}}|{{.State.StartedAt}}|{{.State.FinishedAt}}|{{json .HostConfig.PortBindings}}"] + ids
        )
        // ps と inspect の間に消えたコンテナがあると終了コードは 1 になるが、
        // 残りのコンテナの結果は stdout に出ているのでそのまま使う
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
    /// ISO8601DateFormatter はスレッドセーフなので使い回す(生成コストが高い)
    private static let isoFormatter = ISO8601DateFormatter()

    private static func parseDockerDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            // ISO8601DateFormatter はナノ秒を扱えないので小数部を落とす(タイムゾーン部は残す)
            let zone = text[text.index(after: dot)...].drop { $0.isNumber }
            text = String(text[..<dot]) + zone
        }
        guard
            let date = isoFormatter.date(from: text),
            date.timeIntervalSince1970 > 0
        else { return nil }
        return date
    }

    /// 停止中を含む compose プロジェクト一覧(down 済みでコンテナが無いものは出ない)
    private static func listComposeProjects() -> [ComposeProject] {
        let result = Shell.exec(["docker", "compose", "ls", "-a", "--format", "json"])
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
