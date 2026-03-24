//
//  StemPlayerViewModel.swift
//  PureStems
//
//  AVAudioEngine integration with safe file loading from user-selected folder.
//

import SwiftUI
import AVFoundation
import Accelerate
import Combine

// MARK: - Separation Quality Mode

enum SeparationMode: String, CaseIterable, Identifiable {
    case low = "Low (Fast)"
    case high = "High (Pro)"
    
    var id: String { rawValue }
}

// MARK: - Stem Model

/// The four audio stems the player supports.
enum Stem: String, CaseIterable, Identifiable {
    case bass   = "Bass"
    case drums  = "Drums"
    case other  = "Melody"
    case vocals = "Vocals"

    var id: String { rawValue }

    /// Primary filename (without extension) used for detection and export.
    var fileName: String {
        switch self {
        case .vocals: "vocals"
        case .drums:  "drums"
        case .bass:   "bass"
        case .other:  "melody"
        }
    }

    /// All accepted filenames for detection (includes aliases for Demucs compatibility).
    var fileNames: [String] {
        switch self {
        case .other: ["melody", "other"]
        default:     [fileName]
        }
    }

    /// SF Symbol for each stem's row icon.
    var iconName: String {
        switch self {
        case .vocals: "mic.fill"
        case .drums:  "circle.grid.cross.fill"
        case .bass:   "speaker.wave.3.fill"
        case .other:  "waveform"
        }
    }

    /// Accent color used by the slider for each stem.
    var tintColor: Color {
        switch self {
        case .vocals: .blue
        case .drums:  .orange
        case .bass:   .purple
        case .other:  .green
        }
    }
}

// MARK: - Event Monitor

/// Safely monitors macOS local events (`.keyUp`, `.keyDown`, `.scrollWheel`)
/// to track Cmd+1-4 held states and route volume adjustments.
final class InteractionMonitor: ObservableObject {
    /// Callback when an active shortcut wants to adjust volume by a given delta.
    /// Delta is positive for increase, negative for decrease.
    var onVolumeAdjust: ((Stem, Float) -> Void)?

    /// Base percentage adjustment per "tick" or "tap"
    private let step: Float = 0.02 // 1% equivalent in 0.0-2.0 bipolar scale

    /// Which stem shortcut keys are currently held down (1=Bass, 2=Drums, 3=Melody, 4=Vocals)
    @Published private(set) var activeStemKeys: Set<Int> = []

    /// Accumulator for trackpad dampening
    private var scrollAccumulator: Float = 0.0
    private let scrollThreshold: Float = 3.06 // +25% faster trackpad (3.825 -> 3.06)

    private var eventMonitor: Any?

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .scrollWheel, .flagsChanged]
        ) { [weak self] event in
            guard let self = self else { return event }

            if self.handleEvent(event) {
                // Swallow the event to prevent "funk" beep
                return nil
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Returns `true` if the event should be swallowed, `false` to pass it along.
    private func handleEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            if !event.modifierFlags.contains(.command) {
                activeStemKeys.removeAll()
                scrollAccumulator = 0.0
            }
            return false

        case .keyDown:
            // 1. Check for Command + [1-4] down
            if event.modifierFlags.contains(.command) {
                if let key = keyToNumber(event.keyCode) {
                    activeStemKeys.insert(key)
                    return true // Swallow the shortcut keydown
                }

                // 2. Check for Arrows while command is held (and stems active)
                if !activeStemKeys.isEmpty {
                    if event.keyCode == 126 { // Up arrow
                        applyDelta(step)
                        return true // Swallow the arrow keydown
                    } else if event.keyCode == 125 { // Down arrow
                        applyDelta(-step)
                        return true // Swallow the arrow keydown
                    }
                }
            }
            return false

        case .keyUp:
            if let key = keyToNumber(event.keyCode) {
                activeStemKeys.remove(key)
                if activeStemKeys.isEmpty { scrollAccumulator = 0.0 }
                return true // Swallow the keyup
            }
            return false

        case .scrollWheel:
            guard !activeStemKeys.isEmpty else { return false }

            let rawDelta = Float(event.scrollingDeltaY)
            guard rawDelta != 0 else { return false }

            // Invert scroll delta (scrolling up gives negative Y, but should INCREASE volume).
            let invertedDelta = -rawDelta

            if event.hasPreciseScrollingDeltas {
                // Trackpad: accumulate deltas until threshold is met.
                scrollAccumulator += invertedDelta

                var triggered = false
                while scrollAccumulator >= scrollThreshold {
                    applyDelta(step)
                    scrollAccumulator -= scrollThreshold
                    triggered = true
                }
                while scrollAccumulator <= -scrollThreshold {
                    applyDelta(-step)
                    scrollAccumulator += scrollThreshold
                    triggered = true
                }
                return triggered
            } else {
                // Mouse Wheel: discrete clicks. One click = ~1.65 steps (+25% faster than 1.32)
                let adjustment = (invertedDelta > 0 ? 1.65 : -1.65) * step
                applyDelta(adjustment)
                return true
            }

        default:
            return false
        }
    }

    private func applyDelta(_ delta: Float) {
        // Map keyboard numbers 1,2,3,4 to specific Stems as requested:
        // 1=Bass, 2=Drums, 3=Melody, 4=Vocals
        for key in activeStemKeys {
            let stemTarget: Stem?
            switch key {
            case 1: stemTarget = .bass
            case 2: stemTarget = .drums
            case 3: stemTarget = .other // Note: internal name for Melody
            case 4: stemTarget = .vocals
            default: stemTarget = nil
            }

            if let target = stemTarget {
                onVolumeAdjust?(target, delta)
            }
        }
    }

    /// Map raw macOS key codes to 1-4 integers
    private func keyToNumber(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1 // '1' key
        case 19: return 2 // '2' key
        case 20: return 3 // '3' key
        case 21: return 4 // '4' key
        default: return nil
        }
    }
}

// MARK: - View Model

@Observable
@MainActor
final class StemPlayerViewModel {

    // MARK: - UI State

    /// Individual stem volumes (0.0 … 2.0). 1.0 = original, 2.0 = 200%. UI sliders bind directly.
    var vocalsVolume: Float = 1.0 { didSet { applyVolume(.vocals) } }
    var drumsVolume:  Float = 1.0 { didSet { applyVolume(.drums)  } }
    var bassVolume:   Float = 1.0 { didSet { applyVolume(.bass)   } }
    var otherVolume:  Float = 1.0 { didSet { applyVolume(.other)  } }

    /// Whether the engine is currently playing.
    var isPlaying = false
    
    /// User-selected machine learning model tier for single song.
    var singleSongQuality: SeparationMode = .low
    
    /// User-selected machine learning model tier for batch folder.
    var batchFolderQuality: SeparationMode = .low

    /// Non-nil when something went wrong (shown as an alert in the UI).
    var errorMessage: String?

    /// Convenience for alert binding – set to `false` to clear the error.
    var hasError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    /// Tracks which stem files were successfully loaded.
    var loadedStems: Set<Stem> = []

    /// Whether stems have been loaded (transitions UI from home → player).
    var hasStemsLoaded: Bool { !loadedStems.isEmpty }

    /// The display name of the loaded song / folder.
    var loadedSongName: String?

    /// Album artwork extracted from audio file metadata.
    var albumArtwork: NSImage?

    /// Whether Demucs is currently processing a file.
    var isProcessing = false

    /// Status text shown during processing (e.g., "Separating stems…").
    var processingStatus: String?

    /// The overall progress of the active Demucs separation (0.0…1.0).
    var separationProgress: Double = 0.0

    /// Current playback position in seconds.
    var currentTime: TimeInterval = 0

    /// Total duration of the loaded stems in seconds.
    var duration: TimeInterval = 0

    /// Whether the user is actively scrubbing (suppresses timer updates).
    var isScrubbing = false

    // MARK: - Waveform Extraction
    
    /// Array of normalized amplitude values (0.1 to 1.0) for the timeline UI.
    var waveformData: [CGFloat] = []

    /// Extracts RMS amplitude data from an audio file on a background thread.
    func extractWaveform(from url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 1. Open AVAudioFile safely
                let file = try AVAudioFile(forReading: url)
                let totalFrames = file.length
                guard totalFrames > 0 else { return }
                
                // 3. Formulate chunk sizes (~250 bars for higher density)
                let targetBarCount = 250
                let framesPerBar = AVAudioFrameCount(totalFrames / Int64(targetBarCount))
                
                // 2. Prepare an AVBuffer for our chunk size
                // (Using a streaming approach to prevent massive memory spikes on large audio files)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerBar) else { return }
                
                var rawRMS: [Float] = []
                var maxRMS: Float = 0.0
                
                for _ in 0..<targetBarCount {
                    do {
                        // Read precisely one bar's worth of frames
                        try file.read(into: buffer, frameCount: framesPerBar)
                        
                        guard let channelData = buffer.floatChannelData else { continue }
                        let channelCount = Int(buffer.format.channelCount)
                        let readFrames = Int(buffer.frameLength)
                        
                        // 4. Calculate RMS for this chunk
                        var sumSquares: Float = 0.0
                        for channel in 0..<channelCount {
                            let data = channelData[channel]
                            var channelSumSquares: Float = 0
                            vDSP_dotpr(data, 1, data, 1, &channelSumSquares, vDSP_Length(readFrames))
                            sumSquares += channelSumSquares
                        }
                        
                        let rms = sqrt(sumSquares / Float(readFrames * channelCount))
                        rawRMS.append(rms)
                        
                        if rms > maxRMS { 
                            maxRMS = rms 
                        }
                    } catch {
                        break // Reached EOF or read error
                    }
                }
                
                // 5. Normalize all RMS values to a scale of 0.1 to 1.0 (to fit the UI timeline constraints)
                let normalizedArray: [CGFloat] = rawRMS.map { rms in
                    let normalized = maxRMS > 0 ? CGFloat(rms / maxRMS) : 0
                    let squashed = pow(normalized, 2.5)
                    return max(0.1, min(1.0, squashed)) // Clamp bounds
                }
                
                await MainActor.run {
                    self?.waveformData = normalizedArray
                }
                
            } catch {
                print("Background Waveform Extraction Failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Snippet Mode
    
    var isSnippetMode = false
    var snippetStartTime: TimeInterval = 0.0
    var snippetEndTime: TimeInterval = 10.0
    
    /// Tracks generation of snippet loops to prevent orphaned completion handlers from repeating.
    private var snippetGeneration = 0
    
    /// Tracks playhead logic accurately without module jumping
    private var currentPlayingOrigin: TimeInterval = 0
    private var lastNodeSampleTime: AVAudioFramePosition? = nil

    // MARK: - Multi-Song Queue

    /// Ordered list of source audio files for batch processing.
    var songQueue: [URL] = []

    /// Index of the currently playing song in the queue.
    var currentSongIndex: Int = 0

    /// Maps source file URLs to their Demucs output folders.
    private var separatedFolders: [URL: URL] = [:]

    /// Whether there's a next song in the queue.
    var canGoNext: Bool { currentSongIndex < songQueue.count - 1 }

    /// Whether there's a previous song in the queue.
    var canGoPrev: Bool { currentSongIndex > 0 }

    // MARK: - Audio Engine (private)

    private let engine = AVAudioEngine()
    private var playerNodes: [Stem: AVAudioPlayerNode] = [:]
    private var audioFiles: [Stem: AVAudioFile] = [:]
    private var isEngineSetUp = false
    private let demucsService = DemucsService()
    private var positionTimer: Timer?

    /// The sample rate of the loaded audio (for time ↔ frame conversion).
    private var sampleRate: Double = 44100

    /// Frame offset where playback was last started from (for position calculation).
    private var playbackStartFrame: AVAudioFramePosition = 0

    /// Supported audio extensions for file detection.
    private static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "alac", "wav", "aiff", "flac", "caf"]

    /// Global interaction monitor for scroll and keyboard shortcuts
    let interactionMonitor = InteractionMonitor()
    
    /// Standalone offline rendering service for Snippet Mode exports.
    private let snippetExportService = SnippetExportService()

    // MARK: - Init

    init() {
        setupEngine()

        // Hook up the global event monitor
        interactionMonitor.onVolumeAdjust = { [weak self] stem, delta in
            guard let self = self else { return }

            let currentVal = self.volume(for: stem)
            var newVal = max(0.0, min(2.0, currentVal + delta))

            // Magnetic Snapping at Unity (1.0)
            let snapRange: ClosedRange<Float> = 0.971...1.029 // 25% stronger snap (from ±0.023)
            var didSnap = false

            if snapRange.contains(newVal) && currentVal != 1.0 {
                newVal = 1.0
                didSnap = true
            }

            // Trigger haptic bump precisely when snapping or crossing 100%
            let crossedCenter = (currentVal < 1.0 && newVal >= 1.0) || (currentVal > 1.0 && newVal <= 1.0) || didSnap
            if crossedCenter {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }

            self.setVolume(newVal, for: stem)
        }
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        let mixer = engine.mainMixerNode

        for stem in Stem.allCases {
            let node = AVAudioPlayerNode()
            playerNodes[stem] = node
            engine.attach(node)
            let format = mixer.outputFormat(forBus: 0)
            engine.connect(node, to: mixer, format: format)
        }

        engine.prepare()
        isEngineSetUp = true
    }

    // MARK: - Demucs Separation

    /// Open a single audio file and run Demucs to separate it into stems.
    func openFileForSeparation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Select an audio file to separate into stems"
        panel.prompt = "Separate"

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        Task { await separateAndLoad(fileURL: fileURL) }
    }

    /// Run Demucs on the given file, then load the resulting stems.
    private func separateAndLoad(fileURL: URL) async {
        isProcessing = true
        processingStatus = "Preparing…"
        separationProgress = 0.0
        errorMessage = nil

        do {
            let result = try await demucsService.separate(
                inputFile: fileURL,
                onProgress: { [weak self] status, progress in
                    Task { @MainActor in
                        self?.processingStatus = status
                        if let progress = progress {
                            self?.separationProgress = progress
                        }
                    }
                }
            )

            // Load the separated stems from Demucs output.
            loadStemsFromFolder(result.outputFolder)
            loadedSongName = fileURL.deletingPathExtension().lastPathComponent

            // Extract artwork from the original source file (WAVs from Demucs won't have it).
            if albumArtwork == nil {
                let asset = AVAsset(url: fileURL)
                for item in asset.commonMetadata {
                    if item.commonKey == .commonKeyArtwork,
                       let data = item.dataValue,
                       let img = NSImage(data: data) {
                        albumArtwork = cappedImage(img, maxDimension: 400)
                        break
                    }
                }
            }

        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessing = false
        processingStatus = nil
    }

    /// Open a folder of full songs, separate all of them, and load the first.
    func openSongsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder of songs to separate"
        panel.prompt = "Separate All"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        // Scan for audio files.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            errorMessage = "Could not read folder contents."
            return
        }

        let audioFiles = files.filter {
            Self.supportedExtensions.contains($0.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !audioFiles.isEmpty else {
            errorMessage = "No audio files found in the selected folder."
            return
        }

        songQueue = audioFiles
        currentSongIndex = 0
        separatedFolders.removeAll()

        // Batch-separate all songs.
        Task { await batchSeparate() }
    }

    /// Batch-separate all songs in the queue. Load the first one as soon as it's ready.
    private func batchSeparate() async {
        for (index, fileURL) in songQueue.enumerated() {
            isProcessing = true
            processingStatus = "Separating \(index + 1)/\(songQueue.count): \(fileURL.deletingPathExtension().lastPathComponent)…"
            separationProgress = 0.0

            do {
                let result = try await demucsService.separate(
                    inputFile: fileURL,
                    onProgress: { [weak self] status, progress in
                        Task { @MainActor in
                            self?.processingStatus = "[\(index + 1)/\(self?.songQueue.count ?? 0)] \(status)"
                            if let progress = progress {
                                self?.separationProgress = progress
                            }
                        }
                    }
                )
                separatedFolders[fileURL] = result.outputFolder

                // Load the first song immediately after it finishes.
                if index == 0 {
                    loadSongAtIndex(0)
                }
            } catch {
                errorMessage = "Failed to separate \(fileURL.lastPathComponent): \(error.localizedDescription)"
            }
        }

        isProcessing = false
        processingStatus = nil
    }

    /// Load separated stems for a specific song index.
    func loadSongAtIndex(_ index: Int) {
        guard index >= 0, index < songQueue.count else { return }
        let fileURL = songQueue[index]

        guard let outputFolder = separatedFolders[fileURL] else {
            errorMessage = "Song not yet separated. Please wait…"
            return
        }

        currentSongIndex = index
        loadStemsFromFolder(outputFolder)
        loadedSongName = fileURL.deletingPathExtension().lastPathComponent

        // Extract artwork from the original source file.
        if albumArtwork == nil {
            let asset = AVAsset(url: fileURL)
            for item in asset.commonMetadata {
                if item.commonKey == .commonKeyArtwork,
                   let data = item.dataValue,
                   let img = NSImage(data: data) {
                    albumArtwork = cappedImage(img, maxDimension: 400)
                    break
                }
            }
        }
    }

    /// Navigate to the next song in the queue.
    func nextSong() {
        guard canGoNext else { return }
        loadSongAtIndex(currentSongIndex + 1)
    }

    /// Navigate to the previous song in the queue.
    func previousSong() {
        guard canGoPrev else { return }
        loadSongAtIndex(currentSongIndex - 1)
    }

    /// Cancel a running Demucs separation.
    func cancelSeparation() {
        Task { await demucsService.cancel() }
        isProcessing = false
        processingStatus = nil
    }

    // MARK: - File Loading (from user-selected folder)

    /// Open a folder picker, then scan for stem files inside it.
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing stem files (vocals, drums, bass, melody)"
        panel.prompt = "Load Stems"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        loadStemsFromFolder(folderURL)
    }

    /// Open a file picker for a single audio file to assign to a specific stem.
    func openFileForStem(_ stem: Stem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .mp3, .mpeg4Audio, .aiff, .wav
        ]
        panel.message = "Select an audio file for the \(stem.rawValue) stem"
        panel.prompt = "Load"

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        loadSingleFile(fileURL, for: stem)
    }

    /// Scan a folder for files matching stem names.
    func loadStemsFromFolder(_ folderURL: URL) {
        // Stop any current playback.
        stopAndReset()
        audioFiles.removeAll()
        loadedStems.removeAll()

        var missing: [String] = []

        // List files in the folder.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            errorMessage = "Could not read folder contents."
            return
        }

        for stem in Stem.allCases {
            // Find a file whose name (without extension) matches the stem name (case-insensitive).
            let match = contents.first { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                return stem.fileNames.contains(name) && Self.supportedExtensions.contains(ext)
            }

            if let matchURL = match {
                loadSingleFile(matchURL, for: stem)
            } else {
                missing.append(stem.fileName)
            }
        }

        loadedSongName = folderURL.lastPathComponent

        if !missing.isEmpty && loadedStems.isEmpty {
            errorMessage = "No matching stems found. Expected files named: vocals, drums, bass, melody (mp3/m4a/wav/aiff)"
        } else if !missing.isEmpty {
            errorMessage = "Loaded \(loadedStems.count)/4 stems. Missing: \(missing.joined(separator: ", "))"
        }

        // Try to extract album artwork from any loaded stem.
        extractAlbumArtwork(from: folderURL)
    }

    /// Load a single audio file for a specific stem slot.
    private func loadSingleFile(_ url: URL, for stem: Stem) {
        do {
            let file = try AVAudioFile(forReading: url)
            audioFiles[stem] = file
            
            let isFirstStem = loadedStems.isEmpty
            loadedStems.insert(stem)
            
            if isFirstStem {
                extractWaveform(from: url)
            }

            // Update duration from the longest stem.
            let fileDuration = Double(file.length) / file.processingFormat.sampleRate
            if fileDuration > duration {
                duration = fileDuration
                sampleRate = file.processingFormat.sampleRate
            }

            if loadedSongName == nil {
                loadedSongName = url.deletingPathExtension().lastPathComponent
            }
        } catch {
            errorMessage = "Failed to load \(stem.rawValue): \(error.localizedDescription)"
        }
    }

    /// Extract album artwork from image files in the folder or embedded audio metadata.
    private func extractAlbumArtwork(from folderURL: URL) {
        let fm = FileManager.default
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "bmp", "webp"]
        let preferredNames: [String] = ["cover", "folder", "artwork", "album", "front"]

        // Helper: scan a directory for image files.
        func findCoverImage(in directory: URL) -> NSImage? {
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }

            let imageFiles = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }

            // First pass: prefer known cover names.
            for file in imageFiles {
                let baseName = file.deletingPathExtension().lastPathComponent.lowercased()
                if preferredNames.contains(baseName) {
                    if let img = NSImage(contentsOf: file) { return img }
                }
            }

            // Second pass: use any image file at all.
            if let first = imageFiles.first {
                return NSImage(contentsOf: first)
            }
            return nil
        }

        // Only check the uploaded folder — do NOT search parent directories.
        if let img = findCoverImage(in: folderURL) {
            albumArtwork = cappedImage(img, maxDimension: 400)
            return
        }

        // Fallback: try extracting embedded artwork from loaded audio files.
        for (_, file) in audioFiles {
            let asset = AVAsset(url: file.url)
            for item in asset.commonMetadata {
                if item.commonKey == .commonKeyArtwork,
                   let data = item.dataValue,
                   let img = NSImage(data: data) {
                    albumArtwork = cappedImage(img, maxDimension: 400)
                    return
                }
            }
        }
    }

    /// Scale an image down if it exceeds the max dimension, preserving aspect ratio.
    private func cappedImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }

        let scale = maxDimension / max(size.width, size.height)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    /// Unload everything and return to the home screen.
    func unloadAll() {
        stopAndReset()
        audioFiles.removeAll()
        loadedStems.removeAll()
        loadedSongName = nil
        albumArtwork = nil
        errorMessage = nil
    }

    /// Export all loaded stem WAV files to a user-selected folder.
    func exportStems() {
        guard !audioFiles.isEmpty else {
            errorMessage = "No stems loaded to export."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"

        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        let fm = FileManager.default
        let songName = loadedSongName ?? "PureStems"
        let stemsFolder = destURL.appendingPathComponent("\(songName) Stems")

        // Create the stems subfolder.
        do {
            try fm.createDirectory(at: stemsFolder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Failed to create export folder: \(error.localizedDescription)"
            return
        }

        var exportedCount = 0

        for (stem, file) in audioFiles {
            let sourceURL = file.url
            let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
            let destFile = stemsFolder.appendingPathComponent("\(stem.rawValue).\(ext)")

            do {
                if fm.fileExists(atPath: destFile.path) {
                    try fm.removeItem(at: destFile)
                }
                try fm.copyItem(at: sourceURL, to: destFile)
                exportedCount += 1
            } catch {
                errorMessage = "Failed to export \(stem.rawValue): \(error.localizedDescription)"
            }
        }

        if exportedCount > 0 && errorMessage == nil {
            processingStatus = "Exported \(exportedCount) stem(s) to \(songName) Stems"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.processingStatus = nil
            }
        }
    }

    /// Extrapolates a mixed WAV snippet by calling the offline export service.
    func exportSnippet() {
        guard isSnippetMode, !audioFiles.isEmpty else { return }
        
        let panel = NSSavePanel()
        panel.title = "Export Snippet"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(loadedSongName ?? "Snippet")_Mix.wav"
        
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        
        var sourceURLs: [Stem: URL] = [:]
        var currentVolumes: [Stem: Float] = [:]
        for (stem, file) in audioFiles {
            sourceURLs[stem] = file.url
            currentVolumes[stem] = volume(for: stem)
        }
        
        let wasPlaying = isPlaying
        if isPlaying { pauseAllStems() }
        
        isProcessing = true
        processingStatus = "Exporting Snippet..."
        errorMessage = nil
        
        let startT = snippetStartTime
        let endT = snippetEndTime
        
        Task {
            do {
                try await snippetExportService.exportSnippet(
                    sourceFiles: sourceURLs,
                    volumes: currentVolumes,
                    startTime: startT,
                    endTime: endT,
                    outputURL: outputURL
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.processingStatus = String(format: "Exporting... %.0f%%", progress * 100)
                    }
                }
                
                Task { @MainActor in
                    self.isProcessing = false
                    self.processingStatus = "Export Complete!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        if self?.processingStatus == "Export Complete!" { self?.processingStatus = nil }
                    }
                    if wasPlaying { self.togglePlayback() }
                }
            } catch {
                Task { @MainActor in
                    self.isProcessing = false
                    self.processingStatus = nil
                    self.errorMessage = "Snippet Export Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Snippet Mode

    func toggleSnippetMode() {
        isSnippetMode.toggle()
        if isSnippetMode {
            snippetStartTime = max(0, currentTime)
            snippetEndTime = min(snippetStartTime + 10.0, duration)
            if isPlaying {
                seek(to: snippetStartTime)
            } else {
                currentTime = snippetStartTime
            }
        } else {
            if isPlaying {
                seek(to: currentTime)
            }
        }
    }
    
    func updateSnippetBounds(start: TimeInterval, end: TimeInterval) {
        snippetStartTime = start
        snippetEndTime = end
    }

    /// Recursively queues the exact segment to ensure a gapless loop.
    private func enqueueSnippetSegment(generation: Int, startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount, stems: [Stem]) {
        guard isSnippetMode, isPlaying, snippetGeneration == generation else { return }
        
        for stem in stems {
            guard let node = playerNodes[stem], let file = audioFiles[stem] else { continue }
            // Schedule one iteration, and in its completion, schedule the next to guarantee the queue never runs dry.
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.enqueueSnippetSegment(generation: generation, startFrame: startFrame, frameCount: frameCount, stems: [stem])
                }
            }
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            pauseAllStems()
        } else {
            playAllStems()
        }
    }

    private func playAllStems() {
        guard isEngineSetUp, !audioFiles.isEmpty else {
            errorMessage = "No stems loaded. Please open a folder first."
            return
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                errorMessage = "Engine start failed: \(error.localizedDescription)"
                return
            }
        }
        
        isPlaying = true 
        seek(to: currentTime)
        
        for stem in Stem.allCases { applyVolume(stem) }
        startPositionTimer()
    }

    private func pauseAllStems() {
        stopPositionTimer()
        for node in playerNodes.values {
            node.pause()
        }
        isPlaying = false
    }

    func stopAndReset() {
        snippetGeneration += 1
        stopPositionTimer()
        for node in playerNodes.values {
            node.stop()
        }
        if engine.isRunning { engine.stop() }
        isPlaying = false
        currentTime = 0
        playbackStartFrame = 0
        currentPlayingOrigin = 0
        lastNodeSampleTime = nil
    }

    // MARK: - Seeking

    /// Seek to a specific time in seconds. Re-schedules all stems from that position.
    func seek(to time: TimeInterval) {
        let clampedTime = max(0, min(time, duration))
        currentTime = clampedTime

        let targetFrame = AVAudioFramePosition(clampedTime * sampleRate)
        playbackStartFrame = targetFrame
        currentPlayingOrigin = clampedTime
        lastNodeSampleTime = nil

        let wasPlaying = isPlaying

        // Stop all nodes to clear their schedules.
        for node in playerNodes.values {
            node.stop()
        }

        snippetGeneration += 1
        let gen = snippetGeneration

        // Re-schedule from the target frame.
        for stem in Stem.allCases {
            guard let node = playerNodes[stem],
                  let file = audioFiles[stem] else { continue }

            if isSnippetMode {
               let startF = AVAudioFramePosition(snippetStartTime * sampleRate)
               let endF = AVAudioFramePosition(snippetEndTime * sampleRate)
               let initialStartFrame = max(startF, min(targetFrame, endF))
               
               let initialCount = AVAudioFrameCount(max(0, endF - initialStartFrame))
               let loopCount = AVAudioFrameCount(max(0, endF - startF))
               
               if initialCount > 0 {
                   node.scheduleSegment(file, startingFrame: initialStartFrame, frameCount: initialCount, at: nil) { [weak self] in
                       DispatchQueue.main.async { self?.enqueueSnippetSegment(generation: gen, startFrame: startF, frameCount: loopCount, stems: [stem]) }
                   }
                   if loopCount > 0 {
                       node.scheduleSegment(file, startingFrame: startF, frameCount: loopCount, at: nil) { [weak self] in
                           DispatchQueue.main.async { self?.enqueueSnippetSegment(generation: gen, startFrame: startF, frameCount: loopCount, stems: [stem]) }
                       }
                   }
               }
            } else {
               let fileLength = file.length
               guard targetFrame < fileLength else { continue }

               let remainingFrames = AVAudioFrameCount(fileLength - targetFrame)
               file.framePosition = targetFrame
               node.scheduleSegment(
                   file,
                   startingFrame: targetFrame,
                   frameCount: remainingFrames,
                   at: nil
               )
            }
        }

        // Resume playback if it was playing.
        if wasPlaying {
            let hostTimeNow = mach_absolute_time()
            let delayFrames = AVAudioFramePosition(0.05 * sampleRate)
            let startTime = AVAudioTime(hostTime: hostTimeNow + UInt64(delayFrames))

            for stem in Stem.allCases {
                guard let node = playerNodes[stem],
                      audioFiles[stem] != nil else { continue }
                node.play(at: startTime)
            }
            for stem in Stem.allCases { applyVolume(stem) }
        }
    }

    // MARK: - Position Timer

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentTime()
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func updateCurrentTime() {
        guard isPlaying, !isScrubbing else { return }

        // Use the first loaded stem's player node to determine position.
        guard let stem = loadedStems.first,
              let node = playerNodes[stem],
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }

        let currentSampleTime = playerTime.sampleTime
        let deltaFrames = lastNodeSampleTime.map { currentSampleTime - $0 } ?? 0
        lastNodeSampleTime = currentSampleTime
        
        let deltaTime = Double(max(0, deltaFrames)) / sampleRate
        currentTime += deltaTime

        if isSnippetMode {
            // Keep playback continuous until it crosses the loop threshold natively
            if currentTime >= snippetEndTime {
                let overflow = currentTime - snippetEndTime
                let loopDuration = snippetEndTime - snippetStartTime
                if loopDuration > 0 {
                    let loopTime = overflow.truncatingRemainder(dividingBy: loopDuration)
                    currentTime = snippetStartTime + loopTime
                }
            } else if currentTime < snippetStartTime {
                // Failsafe bounds check
                currentTime = snippetStartTime
            }
        } else {
            let framePosition = playbackStartFrame + playerTime.sampleTime
            let time = Double(framePosition) / sampleRate
            currentTime = max(0, min(time, duration))
        }
    }

    // MARK: - Volume Binding

    private func applyVolume(_ stem: Stem) {
        playerNodes[stem]?.volume = volume(for: stem)
    }

    func volume(for stem: Stem) -> Float {
        switch stem {
        case .vocals: vocalsVolume
        case .drums:  drumsVolume
        case .bass:   bassVolume
        case .other:  otherVolume
        }
    }

    func binding(for stem: Stem) -> Binding<Float> {
        switch stem {
        case .vocals: Binding(get: { self.vocalsVolume }, set: { self.vocalsVolume = $0 })
        case .drums:  Binding(get: { self.drumsVolume },  set: { self.drumsVolume  = $0 })
        case .bass:   Binding(get: { self.bassVolume },   set: { self.bassVolume   = $0 })
        case .other:  Binding(get: { self.otherVolume },  set: { self.otherVolume  = $0 })
        }
    }

    /// Helper to set a specific stem volume programmatically.
    func setVolume(_ value: Float, for stem: Stem) {
        switch stem {
        case .vocals: vocalsVolume = value
        case .drums:  drumsVolume = value
        case .bass:   bassVolume = value
        case .other:  otherVolume = value
        }
    }
}
