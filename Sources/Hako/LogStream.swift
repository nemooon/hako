import Foundation

/// `docker logs -f` のように終わらないコマンドの出力を、届いた分から行ごとに渡す。
/// stdout と stderr は同じパイプで受ける(docker logs はコンテナの stderr を stderr に出すため)
final class LogStream: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var pending = Data()

    /// 引数は Shell.exec と同じく、Homebrew のパスから探してシェルを介さず実行する
    init(executable: String = "/usr/bin/env", arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Shell.environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    /// コンテナのログを追従する。tail は最初に読み込む過去の行数
    static func dockerLogs(container: String, tail: Int) -> LogStream {
        LogStream(arguments: ["docker", "logs", "--follow", "--tail", String(tail), container])
    }

    /// onLines・onExit はバックグラウンドから呼ばれる。
    /// onExit は出力を読み切り、かつプロセスが終わってから一度だけ呼ばれる
    func start(onLines: @escaping @Sendable ([String]) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) -> Bool {
        let finished = DispatchGroup()
        finished.enter() // 出力の終わり
        finished.enter() // プロセスの終了
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                let rest = self.lock.withLock { () -> Data in
                    defer { self.pending = Data() }
                    return self.pending
                }
                if !rest.isEmpty { onLines([Self.decode(rest)]) }
                finished.leave()
                return
            }
            let lines = self.lock.withLock { () -> [String] in
                self.pending.append(data)
                return self.takeCompleteLines()
            }
            if !lines.isEmpty { onLines(lines) }
        }
        process.terminationHandler = { _ in finished.leave() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
        // 子プロセスが書き込み側を握っているので、こちらの書き込み側は閉じて EOF を受け取れるようにする
        try? pipe.fileHandleForWriting.close()
        let process = process
        finished.notify(queue: .global(qos: .utility)) { onExit(process.terminationStatus) }
        return true
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// pending から改行までの行を取り出す(lock を取ってから呼ぶ)
    private func takeCompleteLines() -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Self.decode(pending[pending.startIndex..<newline]))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// 壊れた UTF-8 は置換文字にし、CRLF の CR は落とす
    private static func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
