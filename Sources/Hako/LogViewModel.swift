import Foundation
import Observation

/// ログウィンドウ 1 枚分の状態。行は上限まで保持し、超えたら古いものから捨てる
@Observable
@MainActor
final class LogViewModel {
    enum State: Equatable {
        case streaming
        case ended           // コンテナが止まるなどして追従が終わった
        case failed(Int32)   // docker logs が失敗した(コンテナが無いなど)
    }

    let containerName: String
    private(set) var lines: [String] = []
    /// 追記以外の変化(消去・古い行の切り捨て・読み直し)で増える。表示側は全体を描き直す合図にする
    private(set) var generation = 0
    private(set) var state: State = .streaming
    var query = ""
    var follows = true
    /// ⌘F で検索欄へ移るための合図
    private(set) var searchFocusRequest = 0

    @ObservationIgnored private let maxLines: Int
    @ObservationIgnored private let makeStream: () -> LogStream
    @ObservationIgnored private var stream: LogStream?
    @ObservationIgnored private var session = 0

    init(containerName: String, maxLines: Int = 10_000, makeStream: @escaping () -> LogStream) {
        self.containerName = containerName
        self.maxLines = maxLines
        self.makeStream = makeStream
    }

    /// 読み込みを始める。すでに流れていれば止めて最初から読み直す
    func start() {
        stream?.stop()
        session += 1
        let current = session
        lines = []
        generation += 1
        state = .streaming
        follows = true

        let stream = makeStream()
        self.stream = stream
        // 届いた順に処理したいので、FIFO が保証されるメインキューで受け取る
        let started = stream.start(
            onLines: { [weak self] batch in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.session == current else { return }
                        self.append(batch)
                    }
                }
            },
            onExit: { [weak self] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.session == current else { return }
                        self.state = status == 0 ? .ended : .failed(status)
                        self.stream = nil
                    }
                }
            }
        )
        if !started {
            state = .failed(-1)
            self.stream = nil
        }
    }

    func stop() {
        session += 1
        stream?.stop()
        stream = nil
    }

    func clear() {
        lines = []
        generation += 1
    }

    func requestSearchFocus() { searchFocusRequest += 1 }

    func matches(_ line: String) -> Bool {
        query.isEmpty || line.localizedCaseInsensitiveContains(query)
    }

    private func append(_ batch: [String]) {
        lines += batch.map(Self.stripEscapeSequences)
        // 1 行ごとに捨てると毎回描き直しになるので、上限の 2 割を超えたらまとめて捨てる
        if lines.count > maxLines + maxLines / 5 {
            lines.removeFirst(lines.count - maxLines)
            generation += 1
        }
    }

    /// 文字色などの ANSI エスケープシーケンスを取り除く
    nonisolated static func stripEscapeSequences(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        return line.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }
}
