import Foundation
import Darwin

@main struct QueueBenchmark {
    struct Usage {
        var own: Double
        var children: Double
        var rss: UInt64
        static func read() -> Usage {
            var own = rusage(), children = rusage()
            getrusage(RUSAGE_SELF, &own); getrusage(RUSAGE_CHILDREN, &children)
            func seconds(_ u: rusage) -> Double { Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
            return Usage(own: seconds(own), children: seconds(children), rss: resident(getpid()))
        }
    }
    static func resident(_ pid: Int32) -> UInt64 {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size)) == size ? info.pti_resident_size : 0
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let tools = try ToolLocator.validate(directory: URL(fileURLWithPath: "/opt/homebrew/bin"))
        let state = AppState(persistenceEnabled: false); state.tools = tools
        let source = try await ToolLocator.identify(root.appendingPathComponent("stress.wav"), tools: tools)
        var second = source; second.id = UUID(); second.tracks[0].id = UUID()
        var results: [[String: Any]] = []
        func emit(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        let idleBefore = Usage.read(), idleStart = Date()
        try await Task.sleep(for: .seconds(5))
        let idleAfter = Usage.read(), idleSeconds = Date().timeIntervalSince(idleStart)
        try emit(["scenario": "engine_idle", "wall_s": idleSeconds, "wrapper_cpu_pct": 100 * (idleAfter.own-idleBefore.own)/idleSeconds, "rss_mib": Double(idleAfter.rss)/1048576])
        for index in 0..<12 {
            let mode = index % 3
            var project = StudioProject(files: mode == 1 ? [source, second] : [source], outputPath: root.appendingPathComponent("result-\(index).mkv").path)
            if mode == 1 { project.assemblyMode = .append }
            if mode == 2 { project.splitOptions = SplitOptions(mode: .size, value: "256M") }
            let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
            try state.addJob(job)
            var peakOwn = resident(getpid()), peakChild: UInt64 = 0, samples = 0
            let polling = Task { @MainActor in
                while !Task.isCancelled {
                    peakOwn = max(peakOwn, resident(getpid()))
                    if let pid = state.activeProcessID { peakChild = max(peakChild, resident(pid)) }
                    samples += 1
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                }
            }
            let before = Usage.read(), start = Date()
            await state.execute(job.id)
            let wall = Date().timeIntervalSince(start), after = Usage.read()
            polling.cancel()
            guard let actual = state.jobs.first(where: { $0.id == job.id }), actual.state == .finished || actual.state == .warning else {
                throw StudioError.message(state.jobs.last?.log ?? "No job")
            }
            let summary: [String: Any] = ["scenario": ["remux", "append", "split"][mode], "iteration": index + 1, "wall_s": wall, "wrapper_cpu_pct": 100 * (after.own-before.own)/wall, "utility_cpu_pct": 100 * (after.children-before.children)/wall, "wrapper_peak_rss_mib": Double(peakOwn)/1048576, "utility_peak_rss_mib": Double(peakChild)/1048576, "end_rss_mib": Double(after.rss)/1048576, "samples": samples, "result": actual.state.rawValue]
            results.append(summary); try emit(summary)
            try FileManager.default.removeItem(at: job.output)
            state.clearFinishedJobs()
        }
        let endBefore = Usage.read(), endStart = Date()
        try await Task.sleep(for: .seconds(5))
        let endAfter = Usage.read(), seconds = Date().timeIntervalSince(endStart)
        try emit(["scenario": "engine_after_idle", "wall_s": seconds, "wrapper_cpu_pct": 100 * (endAfter.own-endBefore.own)/seconds, "rss_mib": Double(endAfter.rss)/1048576])
    }
}
