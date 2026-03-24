import Foundation
import AVFoundation

actor SnippetExportService {
    
    // Custom error type for export operations
    enum ExportError: Error, LocalizedError {
        case engineConfigurationFailed(String)
        case missingFileFormat
        case renderingFailed(String)
        case fileWriteFailed(String)
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .engineConfigurationFailed(let msg): return "Engine Configuration Failed: \(msg)"
            case .missingFileFormat: return "Missing Audio Format from source files."
            case .renderingFailed(let msg): return "Audio Rendering Failed: \(msg)"
            case .fileWriteFailed(let msg): return "Could not write to exported file: \(msg)"
            case .cancelled: return "Export cancelled by user."
            }
        }
    }
    
    /// Offline renders the requested snippet mixed from the provided source files.
    func exportSnippet(
        sourceFiles: [Stem: URL],
        volumes: [Stem: Float],
        startTime: TimeInterval,
        endTime: TimeInterval,
        outputURL: URL,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws {
        
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        
        var playerNodes: [Stem: AVAudioPlayerNode] = [:]
        var audioFiles: [Stem: AVAudioFile] = [:]
        
        var targetFormat: AVAudioFormat?
        
        // 1. Prepare files and nodes
        for (stem, url) in sourceFiles {
            let file = try AVAudioFile(forReading: url)
            audioFiles[stem] = file
            
            if targetFormat == nil {
                targetFormat = file.processingFormat
            }
            
            let node = AVAudioPlayerNode()
            playerNodes[stem] = node
            engine.attach(node)
            engine.connect(node, to: mixer, format: file.processingFormat)
            
            // Apply volume
            node.volume = volumes[stem] ?? 1.0
        }
        
        guard let format = targetFormat else {
            throw ExportError.missingFileFormat
        }
        
        // 2. Schedule segments
        let startFrame = AVAudioFramePosition(startTime * format.sampleRate)
        let endFrame = AVAudioFramePosition(endTime * format.sampleRate)
        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
        
        guard frameCount > 0 else {
            throw ExportError.engineConfigurationFailed("Segment duration is 0 or negative.")
        }
        
        for stem in playerNodes.keys {
            guard let node = playerNodes[stem], let file = audioFiles[stem] else { continue }
            // Ensure we don't read past the end of the file
            let actualFrameCount = min(frameCount, AVAudioFrameCount(max(0, file.length - startFrame)))
            if actualFrameCount > 0 {
                node.scheduleSegment(file, startingFrame: startFrame, frameCount: actualFrameCount, at: nil, completionHandler: nil)
            }
        }
        
        // 3. Setup Offline Render
        do {
            let maxFrames: AVAudioFrameCount = 16_384
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        } catch {
            throw ExportError.engineConfigurationFailed(error.localizedDescription)
        }
        
        do {
            try engine.start()
        } catch {
            throw ExportError.engineConfigurationFailed("Failed to start engine: \(error.localizedDescription)")
        }
        
        for node in playerNodes.values {
            node.play()
        }
        
        // 4. Create Output File (.wav)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false)!
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: outFormat.settings)
        } catch {
            throw ExportError.fileWriteFailed(error.localizedDescription)
        }
        
        // 5. Render Loop
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        
        let totalFramesToRender = frameCount
        var framesRendered: AVAudioFramePosition = 0
        var lastReportedProgress: Float = 0.0
        
        while engine.manualRenderingSampleTime < totalFramesToRender {
            let framesRemaining = AVAudioFrameCount(Int64(totalFramesToRender) - engine.manualRenderingSampleTime)
            let framesToRender = min(buffer.frameCapacity, framesRemaining)
            
            do {
                let status = try engine.renderOffline(framesToRender, to: buffer)
                switch status {
                case .success:
                    try outputFile.write(from: buffer)
                    framesRendered += AVAudioFramePosition(framesToRender)
                    
                    // Report progress (throttled to ~2.5% increments)
                    let progress = Float(framesRendered) / Float(totalFramesToRender)
                    if progress - lastReportedProgress >= 0.025 || progress >= 1.0 {
                        onProgress(progress)
                        lastReportedProgress = progress
                    }
                    
                case .error:
                    throw ExportError.renderingFailed("Audio Engine reported an error during offline render.")
                case .insufficientDataFromInputNode:
                    throw ExportError.renderingFailed("Insufficient data from input node.")
                case .cannotDoInCurrentContext:
                    throw ExportError.renderingFailed("Cannot do in current context.")
                @unknown default:
                    throw ExportError.renderingFailed("Unknown manual rendering status.")
                }
            } catch {
                throw ExportError.renderingFailed(error.localizedDescription)
            }
            
            // Check for task cancellation
            if Task.isCancelled {
                engine.stop()
                throw ExportError.cancelled
            }
        }
        
        engine.stop()
    }
}
