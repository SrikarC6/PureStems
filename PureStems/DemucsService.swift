//
//  DemucsService.swift
//  PureStems
//
//  Micro-Step A: Standalone subprocess wrapper for the Demucs CLI.
//  Finds the demucs executable, runs separation, and returns the output path.
//

import Foundation

// MARK: - Demucs Service

/// Manages Demucs CLI invocations for stem separation.
actor DemucsService {

    /// Errors specific to the Demucs workflow.
    enum DemucsError: LocalizedError {
        case notInstalled
        case pythonNotFound
        case separationFailed(String)
        case outputNotFound(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Demucs is not installed. Run: pip3 install demucs"
            case .pythonNotFound:
                return "Python 3 was not found on this system."
            case .separationFailed(let detail):
                return "Demucs failed: \(detail)"
            case .outputNotFound(let path):
                return "Demucs finished but output was not found at: \(path)"
            case .cancelled:
                return "Separation was cancelled."
            }
        }
    }

    /// The result of a successful separation.
    struct SeparationResult {
        let outputFolder: URL      // The folder containing vocals.wav, drums.wav, etc.
        let stemFiles: [String]    // Filenames found in the output folder
    }

    // MARK: - State

    private var currentProcess: Process?

    /// A stream of status messages for UI progress updates.
    typealias ProgressCallback = @Sendable (String, Double?) -> Void

    // MARK: - Public API

    /// Separate an audio file into stems using Demucs.
    ///
    /// - Parameters:
    ///   - inputFile: URL of the audio file to separate.
    ///   - outputDir: Directory where Demucs will write output. Defaults to a temp dir.
    ///   - onProgress: Called with status text as Demucs outputs progress.
    /// - Returns: A `SeparationResult` with the path to the separated stems.
    func separate(
        inputFile: URL,
        outputDir: URL? = nil,
        onProgress: ProgressCallback? = nil
    ) async throws -> SeparationResult {

        // 1. Find the demucs executable.
        let (executable, args) = try findDemucs()

        // 2. Determine output directory.
        let output = outputDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PureStems_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // 3. Build the full argument list.
        //    demucs -n htdemucs_ft --shifts=2 --overlap=0.50 -o <outputDir> <inputFile>
        var fullArgs = args
        fullArgs.append(contentsOf: [
            "-n", "htdemucs_ft",
            "--shifts=2",
            "--overlap=0.50",
            "-o", output.path,
            inputFile.path
        ])

        onProgress?("Starting Demucs separation…", nil)

        // 4. Run the process.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = fullArgs

        // Capture stderr (Demucs writes progress to stderr).
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        // Accumulate all stderr output for error reporting.
        let stderrAccumulator = StderrAccumulator()

        // Add common Python paths to PATH so subprocess can find dependencies.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/Library/Python/3.13/bin",
            NSHomeDirectory() + "/Library/Python/3.12/bin",
            NSHomeDirectory() + "/Library/Python/3.11/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = env

        currentProcess = process

        // Track passes to create one continuous 0-100% progress metric
        var currentPass = 0
        var lastPercentage = 0.0
        let totalPasses = 4.0 

        // Stream stderr for progress and accumulate for error reporting.
        let progressHandle = stderrPipe.fileHandleForReading
        let progressCallback = onProgress
        let accumulator = stderrAccumulator
        
        progressHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            accumulator.append(line)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var percentage: Double? = nil
                if let match = trimmed.range(of: #"([0-9]+)%"#, options: .regularExpression) {
                    let percentStr = String(trimmed[match].dropLast()) // remove "%"
                    if let val = Double(percentStr) {
                        let rawPercent = val / 100.0
                        
                        // Detect pass wrap-around (e.g., jumps from 99% to 0-5% for the next stem)
                        if rawPercent < 0.10 && lastPercentage > 0.90 {
                            currentPass += 1
                        }
                        lastPercentage = rawPercent
                        
                        // Calculate global progress
                        let safePass = min(Double(currentPass), totalPasses - 1)
                        percentage = (safePass + rawPercent) / totalPasses
                    }
                }
                progressCallback?(trimmed, percentage)
            }
        }

        // 5. Launch and wait.
        try Task.checkCancellation()
        
        do {
            try process.run()
        } catch {
            currentProcess = nil
            throw DemucsError.separationFailed("Failed to launch: \(error.localizedDescription)")
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        } onCancel: {
            process.terminate()
        }

        progressHandle.readabilityHandler = nil
        currentProcess = nil

        // 6. Check exit status.
        guard process.terminationStatus == 0 else {
            let allStderr = stderrAccumulator.text
            let detail: String
            if allStderr.contains("No module named demucs") {
                detail = "Demucs is not installed. Run in Terminal:\n  pip3 install demucs"
            } else if allStderr.isEmpty {
                detail = "Exit code \(process.terminationStatus) (no error output captured)"
            } else {
                // Show last 800 chars for context.
                detail = "Exit code \(process.terminationStatus).\n\(String(allStderr.suffix(800)))"
            }
            throw DemucsError.separationFailed(detail)
        }

        onProgress?("Separation complete. Loading stems…", 1.0)

        // 7. Find the output folder.
        //    Demucs creates: <outputDir>/htdemucs/<trackName>/
        //    The model name might vary, so we search for the stem files.
        let result = try findOutputStems(in: output, trackName: inputFile.deletingPathExtension().lastPathComponent)
        return result
    }

    /// Cancel any running separation.
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    // MARK: - Private Helpers

    /// Locate the demucs CLI or fall back to `python3 -m demucs`.
    private func findDemucs() throws -> (executable: String, additionalArgs: [String]) {
        let fm = FileManager.default

        // Common direct paths.
        let directPaths = [
            "/usr/local/bin/demucs",
            "/opt/homebrew/bin/demucs",
            NSHomeDirectory() + "/.local/bin/demucs",
            NSHomeDirectory() + "/Library/Python/3.13/bin/demucs",
            NSHomeDirectory() + "/Library/Python/3.12/bin/demucs",
            NSHomeDirectory() + "/Library/Python/3.11/bin/demucs",
        ]

        for path in directPaths where fm.isExecutableFile(atPath: path) {
            return (path, [])
        }

        // Try `which demucs` via shell.
        if let whichResult = runWhich("demucs"), fm.isExecutableFile(atPath: whichResult) {
            return (whichResult, [])
        }

        // Fall back to python3 -m demucs.
        let pythonPaths = [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for pyPath in pythonPaths where fm.isExecutableFile(atPath: pyPath) {
            return (pyPath, ["-m", "demucs"])
        }

        if let whichPython = runWhich("python3"), fm.isExecutableFile(atPath: whichPython) {
            return (whichPython, ["-m", "demucs"])
        }

        throw DemucsError.notInstalled
    }

    /// Run `which <command>` and return the trimmed output.
    private func runWhich(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Search the Demucs output directory for stem files.
    private func findOutputStems(in outputDir: URL, trackName: String) throws -> SeparationResult {
        let fm = FileManager.default
        let expectedStems = ["vocals", "drums", "bass", "other"]

        // Demucs creates: <outputDir>/<model>/<trackName>/
        // Model name varies (htdemucs, htdemucs_ft, mdx_q, etc.), so search all subdirectories.
        guard let modelDirs = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DemucsError.outputNotFound(outputDir.path)
        }

        for modelDir in modelDirs {
            let trackDir = modelDir.appendingPathComponent(trackName)
            guard fm.fileExists(atPath: trackDir.path) else { continue }

            // Check for stem files (wav or mp3).
            let stemFiles = (try? fm.contentsOfDirectory(atPath: trackDir.path)) ?? []
            let matchingStems = stemFiles.filter { file in
                let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent.lowercased()
                return expectedStems.contains(name)
            }

            if !matchingStems.isEmpty {
                return SeparationResult(outputFolder: trackDir, stemFiles: matchingStems)
            }
        }

        throw DemucsError.outputNotFound("No stems found in \(outputDir.path) for track '\(trackName)'")
    }
}

// MARK: - Stderr Accumulator

/// Thread-safe accumulator for stderr output from the subprocess.
private final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let maxCapacity = 10_000

    func append(_ text: String) {
        lock.lock()
        buffer += text
        if buffer.count > maxCapacity {
            buffer = String(buffer.suffix(maxCapacity))
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
