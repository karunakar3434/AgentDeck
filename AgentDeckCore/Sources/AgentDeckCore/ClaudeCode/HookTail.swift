import Foundation

/// Optional hook hints (architecture §12): if `<dataRoot>/agentdeck/events.jsonl` exists, it is tailed like a
/// transcript, starting at its end on first sight. Each line's `transcript_path` / `agent_transcript_path`
/// is standardized with symlinks resolved; paths inside `<dataRoot>/projects/` are read at once. AgentDeck
/// never writes the file (a user-installed hook appends to it).
extension TranscriptEngine {
    /// Starts tailing at the current end of the hook file, if it exists.
    func registerHookAtEnd() {
        guard hookFile == nil, let st = FileStat.of(path: hookPath), !st.isDirectory else { return }
        hookFile = FileState(path: hookPath, role: .hook, fileID: st.fileID, offset: st.size, size: st.size, mtime: st.mtime)
    }

    func readHook() {
        guard var fs = hookFile else {
            registerHookAtEnd()
            return
        }
        var targets: [String] = []
        let decoder = sidecarDecoder
        let outcome = reader.read(&fs) { line in
            guard let base = line.baseAddress else { return }
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
            guard let event = try? decoder.decode(HookEvent.self, from: data) else { return }
            for path in [event.transcriptPath, event.agentTranscriptPath].compactMap({ $0 }) where !path.isEmpty {
                targets.append(path)
            }
        }
        switch outcome {
        case .reset:
            // Replaced or truncated: start again at its (new) end.
            hookFile = nil
            registerHookAtEnd()
            return
        case .missing:
            hookFile = nil
            return
        case .appended, .unchanged:
            hookFile = fs
        }
        var seen = Set<String>()
        for raw in targets {
            let expanded = (raw as NSString).expandingTildeInPath
            let resolved = classifier.canonical(FileIO.realPath((expanded as NSString).standardizingPath))
            guard seen.insert(resolved).inserted,
                  let components = classifier.relativeComponents(resolved), components.first == "projects" else { continue }
            let role = classifier.classify(resolved)
            switch role {
            case .main, .subagent, .meta, .title:
                process(resolved, role: role)
            default:
                break
            }
        }
    }
}
