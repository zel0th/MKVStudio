"""Run the same integration cases with CLT installations lacking Swift Testing."""
from pathlib import Path
import os, re, subprocess, tempfile
root = Path(__file__).resolve().parent.parent
source = '\n'.join(p.read_text() for p in sorted((root / 'Tests').glob('*.swift')))
source = source.replace('import Testing\n', '').replace('@testable import MKVStudio\n', '')
source = re.sub(r'^\s*@(Test|Suite)\([^\n]*\)\n', '\n', source, flags=re.M)
source = source.replace('try #require(', 'try require(')
source = source.replace('#expect(throws: (any Error).self)', 'try expectThrows')
source = source.replace('await #expect(throws: CancellationError.self)', 'try await expectCancellation')
source = source.replace('#expect(', 'try expect(')
helpers = '''
struct CheckFailure: Error { let message: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Expectation failed", file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else { throw CheckFailure(message: "\\(file):\\(line): \\(message)") }
}
func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(message: message) }; return value
}
func expectThrows(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw CheckFailure(message: "Expected an error")
}
func expectCancellation<T>(_ action: () async throws -> T) async throws {
    do { _ = try await action() } catch is CancellationError { return }
    throw CheckFailure(message: "Expected cancellation")
}
@main struct IntegrationChecks {
    static func main() async throws {
        let tests = EngineTests()
        try await tests.remux(); print("PASS remux, streams, metadata and attachments")
        try await tests.excludeTrack(); print("PASS track and attachment exclusion")
        try await tests.extractAndHeaders(); print("PASS extraction, header edits, mkvinfo")
        try await tests.outputSafety(); print("PASS source and destination protection")
        try await tests.persistence(); print("PASS project round trip")
        try await tests.processOutput(); print("PASS argv safety and large output")
        try await tests.cancellation(); print("PASS process cancellation")
        try await tests.multipleSources(); print("PASS multiple sources with video, audio and subtitles")
        try await tests.appendFiles(); print("PASS append, explicit mappings and PCM equality")
        try await tests.splitFiles(); print("PASS split duration, size, timestamps, parts and PCM equality")
        try await tests.chapters(); print("PASS chapter XML, nested chapters, extraction and chapter splitting")
        try await tests.hdrMetadata(); print("PASS HDR metadata and unchanged video stream")
        try await tests.legacyPersistence(); print("PASS legacy projects and time validation")
        try await tests.boundedOutput(); print("PASS bounded capture and UI mailbox")
        try await tests.independentTools(); print("PASS independent console executable paths")
        let session = SessionTests()
        try session.removeLastSource(); print("PASS last-source removal clears output and title")
        try session.freshSession(); print("PASS fresh launch, termination, queue and preferences")
        try session.toolDirectories(); print("PASS tool picker initial directories")
        try session.settingsPlacement(); print("PASS settings placement across display geometries")
        print("19 integration checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='mkvstudio-checks-') as folder:
    folder = Path(folder)
    check = folder / 'Checks.swift'; check.write_text(source + helpers)
    binary = folder / 'checks'
    files = sorted((root / 'MKVStudio/Core/Models').glob('*.swift')) + sorted((root / 'MKVStudio/Core/Services').glob('*.swift'))
    files += [root / 'MKVStudio/App' / name for name in ['AppState.swift', 'AdvancedState.swift', 'WindowStyling.swift']]
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'MKVStudio-check-modules'), *map(str, files), str(check), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, env={**os.environ, 'MKVSTUDIO_SAMPLE_PATH': str(root/'Samples/Видео.mp4')})
