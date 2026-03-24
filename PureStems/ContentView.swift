//
//  ContentView.swift
//  PureStems
//
//  PureVibes-styled UI with home screen → stem player navigation.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root View

struct ContentView: View {

    @State private var viewModel = StemPlayerViewModel()
    @State private var isAppActive = true

    var body: some View {
        ZStack {
            // Layer 1: Window configuration
            WindowAccessor()

            // Layer 2: OLED black base
            Color.black.ignoresSafeArea()

            // Layer 3: Dynamic art glow (pre-rendered blurred album artwork)
            if let artwork = viewModel.albumArtwork,
               let blurredArt = artwork.blurred(radius: 60) {
                GeometryReader { geo in
                    Image(nsImage: blurredArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .opacity(0.3)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: viewModel.albumArtwork)
            }

            // Layer 4: Under-window material blur
            VisualEffectView().ignoresSafeArea()

            // Layer 5: Faint shimmering dot grid
            FaintGridBackground(isProcessing: viewModel.isProcessing, isAppActive: isAppActive)
                .ignoresSafeArea()
                .zIndex(0.5)

            // — Application content —
            Group {
                if viewModel.isProcessing {
                    ProcessingOverlay(viewModel: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if viewModel.hasStemsLoaded {
                    StemPlayerView(viewModel: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    HomeView(viewModel: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                }
            }
            .zIndex(1)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 540)
        .animation(.easeInOut(duration: 0.4), value: viewModel.hasStemsLoaded)
        .animation(.easeInOut(duration: 0.4), value: viewModel.isProcessing)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isAppActive = false
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.hasError },
            set: { viewModel.hasError = $0 }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

// MARK: - Home View

struct HomeView: View {

    let viewModel: StemPlayerViewModel
    @State private var isHoveringFolder = false
    @State private var isHoveringSeparate = false
    @State private var isHoveringBatch = false
    @State private var pulsePhase = false
    @State private var showQualityTooltipSong = false
    @State private var showQualityTooltipBatch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 36) {
            Spacer()

            // — App icon + title —
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(pulsePhase ? 0.25 : 0.08))
                        .frame(width: 100, height: 100)
                        .blur(radius: 30)

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white.opacity(0.9), .white.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .white.opacity(0.15), radius: 12)
                }
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                        pulsePhase = true
                    }
                }

                Text("PureStems")
                    .font(.custom("Baskerville", size: 38).bold())
                    .foregroundStyle(.white)

                Text("Stem Player")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(3)
                    .textCase(.uppercase)
            }

            Spacer()

            // — Action buttons & Quality Toggle —
            VStack(spacing: 18) {
                // Secondary: Open pre-separated folder
                HStack {
                    Spacer()
                    
                    GlassCapsuleButton(
                        icon: "folder.badge.plus",
                        title: "Open Stems Folder",
                        isHovering: $isHoveringFolder
                    ) {
                        viewModel.openFolder()
                    }
                    .frame(width: 240) // Fixed width to ensure center alignment
                    
                    Spacer()
                }
                
                Divider()
                    .frame(width: 140)
                    .opacity(0.3)
                    .padding(.vertical, 4)

                // Single Song and Batch Folder Sections (Grid Layout)
                Grid(horizontalSpacing: 24, verticalSpacing: 18) {
                    
                    // --- Single Song Row ---
                    GridRow {
                        // Column 1: Action Button
                        GlassCapsuleButton(
                            icon: "wand.and.stars",
                            title: "Separate a Song",
                            isHovering: $isHoveringSeparate
                        ) {
                            viewModel.openFileForSeparation()
                        }
                        .frame(width: 240) 
                        
                        // Column 2: Toggle Group
                        HStack(spacing: 8) {
                            Text("Pro Mode")
                                .font(.custom("Baskerville", size: 14).bold())
                                .foregroundStyle(.white)
                                
                            LiquidGlassToggle(
                                isOn: Binding(
                                    get: { viewModel.singleSongQuality == .high },
                                    set: { viewModel.singleSongQuality = $0 ? .high : .low }
                                )
                            )
                        }
                        .gridColumnAlignment(.leading)
                        
                        // Column 3: Info Icon
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor.opacity(showQualityTooltipSong ? 1.0 : 0.6))
                            .onHover { h in showQualityTooltipSong = h }
                            .popover(isPresented: $showQualityTooltipSong, arrowEdge: .trailing) { qualityTooltipContent }
                    }
                    
                    // --- Batch Folder Row ---
                    GridRow {
                        // Column 1: Action Button
                        GlassCapsuleButton(
                            icon: "music.note.list",
                            title: "Separate a Folder",
                            isHovering: $isHoveringBatch
                        ) {
                            viewModel.openSongsFolder()
                        }
                        .frame(width: 240)
                        
                        // Column 2: Toggle Group
                        HStack(spacing: 8) {
                            Text("Pro Mode")
                                .font(.custom("Baskerville", size: 14).bold())
                                .foregroundStyle(.white)
                                
                            LiquidGlassToggle(
                                isOn: Binding(
                                    get: { viewModel.batchFolderQuality == .high },
                                    set: { viewModel.batchFolderQuality = $0 ? .high : .low }
                                )
                            )
                        }
                        .gridColumnAlignment(.leading)
                        
                        // Column 3: Info Icon
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor.opacity(showQualityTooltipBatch ? 1.0 : 0.6))
                            .onHover { h in showQualityTooltipBatch = h }
                            .popover(isPresented: $showQualityTooltipBatch, arrowEdge: .trailing) { qualityTooltipContent }
                    }
                }

                Text("Supports MP3 · AAC · ALAC · WAV · AIFF · FLAC")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .padding(.top, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Hardware Constraint Tooltip
    
    private var qualityTooltipContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hardware Recommendations")
                .font(.headline)
                
            VStack(alignment: .leading, spacing: 6) {
                Text("**Low (Fast):** Optimized for M1/M2 (Base) chips with 8GB RAM. Uses standard `htdemucs` for rapid, energy-efficient processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    
                Divider().padding(.vertical, 4)
                
                Text("**High (Pro):** Recommended for Pro/Max/Ultra chips with 16GB+ RAM. Uses `htdemucs_ft` with multi-pass averaging for studio-grade isolation. Increases processing time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Glass Capsule Button (reusable)

struct GlassCapsuleButton: View {
    let icon: String
    let title: String
    @Binding var isHovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.custom("Baskerville", size: 15).bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.8),
                                        .white.opacity(0.1),
                                        .white.opacity(0.5)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.0
                            )
                    )
            )
            .shadow(color: Color.accentColor.opacity(isHovering ? 0.6 : 0.4), radius: isHovering ? 12 : 6, x: 0, y: isHovering ? 6 : 3)
            .scaleEffect(isHovering ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
        }
    }
}



// MARK: - Spinning CD View

struct SpinningCDView: View {
    let artwork: NSImage?
    @State private var rotation: Double = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // CD Base (Holographic Silver)
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            Color(white: 0.8),
                            Color(red: 0.9, green: 0.95, blue: 1.0), // Cyan tint
                            Color(white: 0.95),
                            Color(red: 1.0, green: 0.9, blue: 0.95), // Magenta tint
                            Color(white: 0.8),
                            Color(red: 0.9, green: 1.0, blue: 0.9),  // Green/yellow tint
                            Color(white: 0.95),
                            Color(white: 0.8)
                        ],
                        center: .center
                    )
                )

            // Outer Edge Highlight
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.3), .white.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            
            // Subdued Inner Radial Gradient to simulate optical disc depth
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.clear, Color.black.opacity(0.05), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 70
                    )
                )

            // CD Track Grooves
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                    .padding(CGFloat(i) * 10 + 20)
            }

            // Center Label Ring
            ZStack {
                // Metallic ring around the artwork
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.7), Color(white: 0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.2), radius: 2)
                
                if let artwork = artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color(white: 0.15))
                        .frame(width: 44, height: 44)
                }
                
                // Spindle Hole
                Circle()
                    .fill(Color.black.opacity(0.8))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            }
        }
        .frame(width: 160, height: 160)
        .rotationEffect(.degrees(rotation))
        .shadow(color: .black.opacity(0.4), radius: 15, x: 0, y: 8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Processing Overlay

struct ProcessingOverlay: View {
    let viewModel: StemPlayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            // 1. Spinning CD
            SpinningCDView(artwork: viewModel.albumArtwork)

            // 2. Progress Percentage
            Text("\(Int(round(viewModel.separationProgress * 100)))%")
                .font(.custom("Baskerville", size: 48).bold())
                .foregroundStyle(.white)
                .monospacedDigit()
            
            // 3. Cancel button
            Button {
                viewModel.cancelSeparation()
            } label: {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                            .overlay(
                                Capsule()
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                .white.opacity(0.8),
                                                .white.opacity(0.1),
                                                .white.opacity(0.5)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.0
                                    )
                            )
                    )
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - Bracket Shape

struct BracketShape: Shape {
    let isLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tickLength: CGFloat = 8
        
        // Flipped logic: Left bracket is at minX pointing right, Right bracket is at maxX pointing left.
        let startX = isLeft ? rect.minX : rect.maxX
        let innerX = isLeft ? rect.minX + tickLength : rect.maxX - tickLength
        
        path.move(to: CGPoint(x: innerX, y: rect.minY))
        path.addLine(to: CGPoint(x: startX, y: rect.minY))
        path.addLine(to: CGPoint(x: startX, y: rect.maxY))
        path.addLine(to: CGPoint(x: innerX, y: rect.maxY))
        
        return path
    }
}

// MARK: - Stem Player View

struct StemPlayerView: View {

    let viewModel: StemPlayerViewModel
    @State private var scrubIsHovered = false
    @State private var tiltX: Double = 0
    @State private var tiltY: Double = 0
    @State private var coverIsHovered = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                playerHeader
                Spacer()
                contentPanel
                
                if viewModel.isSnippetMode {
                    SnippetTimelineView(viewModel: viewModel)
                        .padding(.vertical, 32)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                Spacer()
                    .frame(height: 80)
            }
            .padding(.vertical, 20)
        }
        .overlay(alignment: .bottom) {
            pillBar
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.isSnippetMode)
    }

    // MARK: - Header

    private var playerHeader: some View {
        HStack(spacing: 10) {
            GlassButton(icon: "chevron.left", size: 32, iconSize: 12) {
                viewModel.unloadAll()
            }

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white.opacity(0.8), .white.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.loadedSongName ?? "PureStems")
                    .font(.custom("Baskerville", size: 18).bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(viewModel.loadedStems.count)/4 stems loaded")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Export stems / snippet
            Button {
                if viewModel.isSnippetMode {
                    viewModel.exportSnippet()
                } else {
                    viewModel.exportStems()
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(viewModel.isSnippetMode ? Color.accentColor : .white)
                    .shadow(color: viewModel.isSnippetMode ? .accentColor : .clear, radius: 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }

    // MARK: - Content Panel (Album Cover + Mixer)

    private var contentPanel: some View {
        GeometryReader { geo in
            if viewModel.albumArtwork != nil {
                // Album art (left, ~35%) + Stem panel (right, fills remainder)
                let artWidth = geo.size.width * 0.35
                let gap: CGFloat = 16
                let stemWidth = geo.size.width - artWidth - gap

                HStack(spacing: gap) {
                    albumCover
                        .frame(width: artWidth, height: geo.size.height)

                    stemPanel
                        .frame(width: stemWidth, height: geo.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No artwork: full-width stem panel
                stemPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Album Cover

    private var albumCover: some View {
        GeometryReader { geo in
            ZStack {
                // Dark base
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))

                // Liquid glass sheen — moves with tilt
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.0),
                                .white.opacity(coverIsHovered ? 0.12 : 0.03),
                                .white.opacity(0.0)
                            ],
                            startPoint: UnitPoint(
                                x: 0.3 + tiltX * 0.3,
                                y: 0.2 + tiltY * 0.3
                            ),
                            endPoint: UnitPoint(
                                x: 0.7 + tiltX * 0.3,
                                y: 0.8 + tiltY * 0.3
                            )
                        )
                    )

                // Shiny border
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.5),
                                .white.opacity(0.05),
                                .white.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Album artwork or placeholder
                if let artwork = viewModel.albumArtwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.2))

                        Text(viewModel.loadedSongName ?? "No Track")
                            .font(.custom("Baskerville", size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }

                // Liquid glass reflective sheen
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.12),
                                .white.opacity(0.0),
                                .white.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
            .rotation3DEffect(
                .degrees(tiltY * 8),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.5
            )
            .rotation3DEffect(
                .degrees(-tiltX * 8),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
            .scaleEffect(coverIsHovered ? 1.02 : 1.0)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: tiltX)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: tiltY)
            .animation(.easeOut(duration: 0.3), value: coverIsHovered)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    coverIsHovered = true
                    let newX = (location.x / geo.size.width - 0.5) * 2
                    let newY = (location.y / geo.size.height - 0.5) * 2
                    // Only update if moved significantly (reduces redraws by ~80%)
                    if abs(newX - tiltX) > 0.02 || abs(newY - tiltY) > 0.02 {
                        tiltX = newX
                        tiltY = newY
                    }
                case .ended:
                    coverIsHovered = false
                    tiltX = 0
                    tiltY = 0
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(0.85)
    }

    // MARK: - Stem Panel

    private var stemPanel: some View {
        HStack(spacing: 0) {
            ForEach(Stem.allCases) { stem in
                VerticalStemSlider(
                    stem: stem,
                    volume: viewModel.binding(for: stem),
                    isLoaded: viewModel.loadedStems.contains(stem)
                )

                if stem != Stem.allCases.last {
                    Divider()
                        .frame(height: 180)
                        .opacity(0.15)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .glassPanel()
    }

    // MARK: - Bottom Pill Bar

    private var pillBar: some View {
        HStack(spacing: 14) {
            if !viewModel.isSnippetMode {
                // Scrubber (compact)
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                // Removed inline snippet scrubber - now exclusively using standardScrubber
                standardScrubber

                Text(formatTime(viewModel.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Snippet Toggle
            Button {
                viewModel.toggleSnippetMode()
            } label: {
                Image(systemName: viewModel.isSnippetMode ? "scissors.badge.ellipsis" : "scissors")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(viewModel.isSnippetMode ? Color.accentColor : Color.accentColor.opacity(0.5))
            }
            .buttonStyle(.plain)

            // Previous
            Button { viewModel.previousSong() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(viewModel.canGoPrev ? 0.7 : 0.2))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoPrev)

            // Play / Pause
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying
                      ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            // Next
            Button { viewModel.nextSong() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(viewModel.canGoNext ? 0.7 : 0.2))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoNext)

            // Folder
            Button {
                viewModel.openFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Material.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.7),
                            .white.opacity(0.1),
                            .white.opacity(0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 10)
    }
    
    // MARK: - Standard Scrubber
    
    private var standardScrubber: some View {
        GeometryReader { geo in
            let progress = viewModel.duration > 0
                ? CGFloat(viewModel.currentTime / viewModel.duration)
                : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.7),
                                Color.accentColor.opacity(0.3)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * progress)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white)
                    .frame(width: 3, height: scrubIsHovered ? 16 : 12)
                    .shadow(color: .white.opacity(0.4), radius: 3)
                    .offset(x: (geo.size.width * progress) - 1.5)
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        viewModel.isScrubbing = true
                        let fraction = value.location.x / geo.size.width
                        let time = Double(max(0, min(1, fraction)))
                            * viewModel.duration
                        viewModel.currentTime = time
                    }
                    .onEnded { value in
                        let fraction = value.location.x / geo.size.width
                        let time = Double(max(0, min(1, fraction)))
                            * viewModel.duration
                        viewModel.seek(to: time)
                        viewModel.isScrubbing = false
                    }
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    scrubIsHovered = hovering
                }
            }
        }
        .frame(width: 140, height: 20)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Vertical Stem Slider

struct VerticalStemSlider: View {

    let stem: Stem
    @Binding var volume: Float
    var isLoaded: Bool = true

    @State private var isHovered = false
    @State private var previousVolume: Float = 1.0

    /// Fraction 0…1 representing volume mapped to track position (0 = bottom, 0.5 = center/100%, 1 = top/200%).
    private var fraction: CGFloat {
        CGFloat(volume / 2.0)
    }

    var body: some View {
        VStack(spacing: 14) {
            // — Percentage display —
            Text("\(Int(volume * 100))")
                .font(.system(size: 22, weight: .light, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))

            Text("%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .offset(y: -8)

            // — Vertical slider track —
            GeometryReader { geo in
                let midY = geo.size.height / 2

                ZStack {
                    // Background track (slim profile)
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 20)

                    // Center line (100% marker)
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 20, height: 1)
                        .position(x: geo.size.width / 2, y: midY)

                    // Filled portion — extends from center up (boost) or center down (cut)
                    let fillHeight = abs(fraction - 0.5) * geo.size.height
                    let fillY = fraction >= 0.5
                        ? midY - fillHeight / 2  // Boost: fill above center
                        : midY + fillHeight / 2  // Cut: fill below center

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.9),
                                    Color.accentColor.opacity(0.35)
                                ],
                                startPoint: fraction >= 0.5 ? .bottom : .top,
                                endPoint: fraction >= 0.5 ? .top : .bottom
                            )
                        )
                        .frame(width: 20, height: max(fillHeight, 2))
                        .position(x: geo.size.width / 2, y: fillY)

                    // Line handle at current volume position
                    let handleY = geo.size.height * (1 - fraction)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 48, height: 4)
                        .shadow(color: .white.opacity(0.3), radius: 4)
                        .position(x: geo.size.width / 2, y: handleY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    isLoaded
                        ? DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let rawFraction = 1.0 - (value.location.y / geo.size.height)
                                var clamped = Float(max(0, min(1, rawFraction))) * 2.0

                                // Magnetic Snapping at Unity (1.0)
                                let snapRange: ClosedRange<Float> = 0.971...1.029 // 25% stronger snap (from ±0.023)
                                var didSnap = false

                                if snapRange.contains(clamped) && previousVolume != 1.0 {
                                    clamped = 1.0
                                    didSnap = true
                                }

                                // Haptic bump when crossing the center (100%) or snapping
                                let crossedCenter = (previousVolume < 1.0 && clamped >= 1.0)
                                    || (previousVolume > 1.0 && clamped <= 1.0)
                                    || didSnap

                                if crossedCenter {
                                    NSHapticFeedbackManager.defaultPerformer.perform(
                                        .alignment,
                                        performanceTime: .now
                                    )
                                }
                                previousVolume = clamped
                                volume = clamped
                            }
                        : nil
                )
            }
            .frame(height: 240)

            // — Icon —
            Image(systemName: stem.iconName)
                .font(.system(size: 16))
                .foregroundStyle(isLoaded ? Color.accentColor : .secondary.opacity(0.3))
                .frame(height: 20)

            // — Label —
            Text(stem.rawValue)
                .font(.custom("Baskerville", size: 13))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .opacity(isLoaded ? 1 : 0.35)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Snippet Timeline View

struct SnippetTimelineView: View {
    @Bindable var viewModel: StemPlayerViewModel
    
    @State private var hoverStart = false
    @State private var hoverEnd = false
    @State private var isHoveringExport = false
    @State private var lastSnappedTime: TimeInterval? = nil
    
    let minimumSnippetGap: TimeInterval = 1.0
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let duration = viewModel.duration > 0 ? viewModel.duration : 1
            
            let startFrac = CGFloat(viewModel.snippetStartTime / duration)
            let endFrac = CGFloat(viewModel.snippetEndTime / duration)
            
            let startX = startFrac * w
            let endX = endFrac * w
            
            ZStack(alignment: .leading) {
                // Background Base (Removed ultraThinMaterial as requested)
                    
                // --- Waveform Rendering ---
                // 3. Formulate chunk sizes (~500 bars for extremely high density)
                let targetBarCount = 500
                let data = viewModel.waveformData
                let count = data.count
                if count > 0 {
                    let effectiveCount = max(1, count - 1)
                    ForEach(0..<count, id: \.self) { index in
                        // Map index to a position from 16 to w-16
                        let fraction = CGFloat(index) / CGFloat(effectiveCount)
                        let barXPosition = 16 + fraction * (w - 32)
                        let isSelected = barXPosition >= startX && barXPosition <= endX
                        
                        let barHeight = max(4.0, data[index] * 64.0) // Safely fits inside the 80pt frame
                        
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isSelected ? Color.accentColor : Color.white.opacity(0.3))
                            .frame(width: 1.5, height: barHeight)
                            .position(x: barXPosition, y: geo.size.height / 2) // Centered vertically
                            .animation(.easeOut(duration: 0.2), value: isSelected)
                    }
                } else {
                    // Fallback/Loading state before waveform is generated
                    Text("Extracting Waveform…")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .position(x: w / 2, y: geo.size.height / 2)
                }
                
                // Playhead representation inside the timeline
                if viewModel.currentTime >= viewModel.snippetStartTime && viewModel.currentTime <= viewModel.snippetEndTime {
                    let currentFrac = CGFloat(viewModel.currentTime / duration)
                    let currentX = currentFrac * w
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: geo.size.height)
                        .contentShape(Rectangle().inset(by: -12))
                        .position(x: currentX, y: geo.size.height / 2)
                        .zIndex(5)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    viewModel.isScrubbing = true
                                    let newTime = (val.location.x / w) * duration
                                    viewModel.currentTime = max(viewModel.snippetStartTime, min(newTime, viewModel.snippetEndTime))
                                }
                                .onEnded { _ in
                                    viewModel.seek(to: viewModel.currentTime)
                                    viewModel.isScrubbing = false
                                }
                        )
                }

                // Start Handle
                timelineHandle(time: viewModel.snippetStartTime, isLeft: true, xPos: startX, yPos: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { val in handleTimelineDrag(val, for: .start, width: w, duration: duration) }
                            .onEnded { _ in lastSnappedTime = nil }
                    )
                    .zIndex(3)

                // End Handle
                timelineHandle(time: viewModel.snippetEndTime, isLeft: false, xPos: endX, yPos: geo.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { val in handleTimelineDrag(val, for: .end, width: w, duration: duration) }
                            .onEnded { _ in lastSnappedTime = nil }
                    )
                    .zIndex(3)
                
            }
            .coordinateSpace(name: "timeline")
            .frame(height: 80)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 80) // Locks GeometryReader height
    }
    
    @ViewBuilder
    private func timelineHandle(time: TimeInterval, isLeft: Bool, xPos: CGFloat, yPos: CGFloat) -> some View {
        BracketShape(isLeft: isLeft)
            .stroke(Color.white, lineWidth: 3)
            .frame(width: 12, height: 110)
            .contentShape(Rectangle().inset(by: -8)) // Make the handle easier to grab
            .overlay(alignment: .top) {
                Text(formatSnippetTime(time))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize() // Prevents vertical text wrapping
                    .offset(y: -20)
            }
            .position(x: xPos, y: yPos) // Absolute positioning prevents gesture desync
    }
    
    private func formatSnippetTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    enum TimelineHandleType { case start, end }
    
    private func handleTimelineDrag(_ value: DragGesture.Value, for handle: TimelineHandleType, width: CGFloat, duration: TimeInterval) {
        let rawFraction = value.location.x / width
        let rawTime = Double(max(0, min(1, rawFraction))) * duration
        
        // PureVibes Magnetic Snap Logic (Very Slight)
        let wholeSecond = round(rawTime)
        let distanceToWhole = abs(rawTime - wholeSecond)
        
        var snappedTime = rawTime
        if distanceToWhole < 0.05 { // ~2.5% gravity well natively, VERY slight snapping
            snappedTime = wholeSecond
            lastSnappedTime = wholeSecond
        } else {
            lastSnappedTime = nil
        }
        
        switch handle {
        case .start:
            let clampedStart = min(snappedTime, viewModel.snippetEndTime - minimumSnippetGap)
            viewModel.updateSnippetBounds(start: clampedStart, end: viewModel.snippetEndTime)
        case .end:
            let clampedEnd = max(snappedTime, viewModel.snippetStartTime + minimumSnippetGap)
            viewModel.updateSnippetBounds(start: viewModel.snippetStartTime, end: clampedEnd)
        }
    }
}

// MARK: - Export Snippet Button

struct ExportSnippetButton: View {
    let action: () -> Void
    @State private var isPulsing = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 80, height: 80) // Match timeline height exactly
                .background(
                    // Solid Base
                    Circle()
                        .fill(Color.accentColor)
                )
                .overlay(
                    // Liquid Glass Border
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.8),
                                    .white.opacity(0.1),
                                    .white.opacity(0.5)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(
                    color: Color.accentColor.opacity(isPulsing ? 0.8 : 0.2), 
                    radius: isPulsing ? 16 : 8, 
                    x: 0, 
                    y: isPulsing ? 4 : 2
                )
                .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.2)) { isHovering = h }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
