import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Homebrew のパスを含めたうえでコマンドを同期実行する(呼び出し側でバックグラウンドキューに載せること)
    @discardableResult
    static func run(_ command: String) -> Result {
        runProgram("/bin/zsh", ["-c", command])
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

        // waitUntilExit の前に読み切ることで、パイプのバッファ詰まりを防ぐ
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// バックグラウンドで実行し、完了時にメインスレッドでコールバックする
    static func runAsync(_ command: String, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(command)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
