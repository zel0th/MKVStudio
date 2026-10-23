"""Run the same integration cases with CLT installations lacking Swift Testing."""
from pathlib import Path
import os, re, subprocess, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from isolated_tools import isolated_command
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
func print(_ value: String) { FileHandle.standardOutput.write(Data((value + "\\n").utf8)) }
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
        try await session.completedWorkspace(); print("PASS successful remux, append, split, headers and extraction clear every editor")
        try await session.completionOutcomes(); print("PASS warning reset; failed, cancelled and unpublished jobs preserve work")
        try await session.newerWorkSurvives(); print("PASS queued snapshots and newer edits survive older job completion")
        try await session.lateReaders(); print("PASS late chapter and information reads cannot restore cleared fields")
        let metadata = MetadataTests()
        try metadata.preservation(); print("PASS standard tags, nesting, languages, targets and validation")
        try await metadata.realTags(); print("PASS real tag edits in remux, append and split; queue snapshot; unchanged streams")
        try await metadata.previews(); print("PASS attachment and tag previews, limits, safe paths and cleanup")
        try await metadata.absentTags(); print("PASS absent Tags: editor, preview, first write and extraction errors")
        let kinopoisk = KinopoiskTests()
        try await kinopoisk.requests(); print("PASS API requests, schema and credential isolation")
        try await kinopoisk.failures(); print("PASS API failures, invalid images and cancellation")
        try await kinopoisk.importing(); print("PASS selected online tags/poster through real remux, queue persistence and unchanged streams")
        try await kinopoisk.atomicity(); print("PASS series scope, language conflicts, stale workspace and atomic import")
        try await kinopoisk.http(); print("PASS actual bounded HTTP transport, redirects and cancellation")
        try await kinopoisk.untaggedSource(); print("PASS online selection and import for MKV without Tags; unchanged streams")
        let bundled = BundledToolsTests()
        try bundled.discovery(); print("PASS bundled precedence, external overrides, missing helpers and no host tools")
        try await bundled.relocation(); print("PASS relocated queued tools, tag processing and real output")
        print("35 integration checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='mkvstudio-checks-') as folder:
    folder = Path(folder)
    check = folder / 'Checks.swift'; check.write_text(source + helpers)
    binary = folder / 'checks'
    files = sorted((root / 'MKVStudio/Core/Models').glob('*.swift')) + sorted((root / 'MKVStudio/Core/Services').glob('*.swift'))
    files += [root / 'MKVStudio/App' / name for name in ['AppState.swift', 'MetadataState.swift', 'KinopoiskState.swift', 'AdvancedState.swift', 'WindowStyling.swift']]
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'MKVStudio-check-modules'), *map(str, files), str(check), '-o', str(binary)], check=True)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            try:
                if self.path == '/slow': time.sleep(2)
                if self.path == '/redirect':
                    self.send_response(302); self.send_header('Location', '/ok'); self.end_headers(); return
                self.send_response(200)
                if self.path == '/large-header': self.send_header('Content-Length', '1000000')
                self.end_headers()
                self.wfile.write(b'x'*4096 if self.path in ['/large-header','/large-chunks'] else b'okay')
            except (BrokenPipeError, ConnectionResetError): pass
    server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(isolated_command([str(binary)]), check=True, env={**os.environ, 'MKVSTUDIO_SAMPLE_PATH': str(root/'Samples/Видео.mp4'), 'MKVSTUDIO_HTTP_FIXTURE': f'http://127.0.0.1:{server.server_port}'})
    finally: server.shutdown(); server.server_close()
