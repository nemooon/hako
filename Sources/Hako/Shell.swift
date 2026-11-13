import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// シェル構文(パイプやリダイレクト)が必要なコマンドを zsh 経由で同期実行する
    @discardableResult
    static func run(_ command: String) -> Result {
        runProgram("/bin/zsh", ["-c", command])
    }

    /// docker / colima などを Homebrew のパスから探して、シェルを介さず同期実行する。
    /// 引数はそのまま渡るのでクォートは不要(呼び出し側でバックグラウンドキューに載せること)
    @discardableResult
    static func exec(_ arguments: [String]) -> Result {
        runProgram("/usr/bin/env", arguments)
    }

    /// シェルに渡す文字列を単一引用符で安全に囲む(Terminal で実行するコマンド向け)
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// 表示用にコマンドを 1 行の文字列にする
    static func display(_ arguments: [String]) -> String {
        arguments.map { $0.contains(where: { " '\"$".contains($0) }) ? quote($0) : $0 }.joined(separator: " ")
    }

    /// シェルを介さず実行する(AppleScript などクォートが厄介なもの向け)
    @discardableResult
    static func runProgram(_ path: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        // waitUntilExit の前に読み切ることで、パイプのバッファ詰まりを防ぐ。
        // 片方ずつ順に読むと、もう片方のバッファ(約 64KB)が埋まった時点で互いに待ち合うため、
        // stderr は別スレッドで同時に読む
        var stderrData = Data()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDone.wait()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// バックグラウンドで実行し、完了時にメインスレッドでコールバックする
    static func execAsync(_ arguments: [String], completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = exec(arguments)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
