import Foundation
import Combine

@MainActor
final class BackendManager: ObservableObject {

    enum Status: Equatable {
        case notStarted
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .notStarted

    private var process: Process?

    private let projectPath = "/Users/max/Desktop/project_stella"
    private let pythonPath = "/Users/max/Desktop/project_stella/venv/bin/python3"
    private let healthURL = URL(string: "http://127.0.0.1:8000/health")!

    func start() {
        guard process == nil else { return }
        status = .starting

        Task {
            await killAnyExistingBackend()

            let task = Process()
            task.executableURL = URL(fileURLWithPath: pythonPath)
            task.arguments = ["-m", "uvicorn", "api:app", "--host", "127.0.0.1", "--port", "8000"]
            task.currentDirectoryURL = URL(fileURLWithPath: projectPath)

            let logURL = URL(fileURLWithPath: projectPath).appendingPathComponent("backend.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let logHandle = try? FileHandle(forWritingTo: logURL) {
                task.standardOutput = logHandle
                task.standardError = logHandle
            }

            task.terminationHandler = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.process = nil
                    if self.status == .ready {
                        self.status = .failed("Backend stopped unexpectedly")
                    }
                }
            }

            do {
                try task.run()
                process = task
                await waitUntilReady()
            } catch {
                status = .failed("Couldn't launch backend: \(error.localizedDescription)")
            }
        }
    }

    private func killAnyExistingBackend() async {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "uvicorn api:app"]
        try? kill.run()
        kill.waitUntilExit()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func waitUntilReady(timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: healthURL),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                status = .ready
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        status = .failed("Backend didn't respond within \(Int(timeout))s -- check backend.log")
    }
}
