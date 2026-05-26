import Foundation
import EditorCore

/// Registry of all tools available to AI models.
/// Each tool maps to EditorIntents — same execution path as human actions.
public struct AIToolRegistry: Sendable {

    public static let allTools: [AIToolDefinition] = [
        addTrack,
        insertClip,
        moveClip,
        deleteClips,
        splitClip,
        trimClip,
        setMarker,
        removeSilence,
        setClipVolume,
        setClipOpacity,
        setClipSpeed,
        muteTrack,
        duplicateClip,
        setClipEffect,
        removeSection,
        rippleDelete,
        normalizeAudio,
        removeTrack,
        lockTrack,
        setTrackVolume,
        renameClip,
        setClipTransition,
        deleteMarker,
        setClipTransform,
        setClipKeyframes,
        rollTrim,
        slipClip,
        rippleTrim,
        autoReframe,
        detectBeats,
        scoreThumbnails,
        suggestBroll,
        applyPersonMask,
        trackObject,
        voiceCleanup,
        denoiseAudio,
        denoiseVideo,
        stabilizeVideo,
        setCaptionStyle,
        applyLUT,
        measureLoudness,
        autoDuck,
        chromaKey,
        getTranscript,
        getVisualScenes,
        transcribeAsset,
        searchTranscript,
        deleteAsset,
        setOverlayConfig,
        getOverlayConfig,
        // Content analysis tools (handled by AIChatController / MCPServer, not AIToolResolver)
        getState,
        autoCut,
        analyzeTranscript,
        findViralMoments,
        uploadShortToLibrary,
        getFullTranscript,
        analyzeAudioEnergy,
        classifyAudio,
        scoreContent,
        segmentTopics,
        verifyPlayback,
        setClipCrop,
        setClipBlendMode,
        removeClipEffect,
        setClipOverlayPresentation,
        applyPiPPreset,
        soloTrack,
        renameTrack,
        reorderTrack,
        linkClips,
        batch,
        // AppState tools (handled by AIChatController/MCPServer, not AIToolResolver)
        undo,
        redo,
        playPause,
        seek,
        toggleLoop,
        getActionLog,
        activateSkill,
        // Image generation tools
        generateThumbnail,
        generateCarousel,
        // Audio processing tools
        applyGate,
        applyCompressor,
        applyDeEsser,
        applyEQ,
        applyLimiter,
        normalizeAudioToLUFS,
        analyzeAudioSpectrum,
        applySpectralNoiseReduction,
        // Graphics tools
        addTextOverlay,
        addZoomEffect,
        // Animation tools
        applySpeedRamp,
        // Caption tools
        setCaptionTiming,
        // Export tools
        exportVideo,
    ]

    // MARK: - Content tools (request data on demand, save tokens)

    public static let getTranscript = AIToolDefinition(
        name: "get_transcript",
        description: "Get the transcript text for a specific asset or clip. Call this ONLY when you need to read what's being said (e.g., finding ums, searching for topics, content-aware editing). Do NOT call for structural edits like moving/splitting/deleting clips.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset to get transcript for"),
        ], required: ["asset_id"])
    )

    public static let getVisualScenes = AIToolDefinition(
        name: "get_visual_scenes",
        description: "Get visual scene descriptions for an asset. Returns scene boundaries with natural language descriptions of what's visually happening (people, actions, setting, mood). Only available after visual analysis completes on import.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset to get visual scenes for"),
            "start_time": .init(type: "number", description: "Optional: only return scenes after this time (seconds)"),
            "end_time": .init(type: "number", description: "Optional: only return scenes before this time (seconds)"),
        ], required: ["asset_id"])
    )

    public static let transcribeAsset = AIToolDefinition(
        name: "transcribe_asset",
        description: "Transcribe a media asset that hasn't been transcribed yet. This sends audio to a transcription service and may take a moment. Only call if get_transcript returns no transcript. Supports cloud (Deepgram, default) or local (WhisperKit, offline, free) providers.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset to transcribe"),
            "provider": .init(type: "string", description: "Transcription provider: 'deepgram' (default, cloud, supports diarization) or 'local'/'whisper' (WhisperKit, offline, free, no diarization)"),
        ], required: ["asset_id"])
    )

    public static let searchTranscript = AIToolDefinition(
        name: "search_transcript",
        description: "Search across all transcribed assets for mentions of a word or phrase. Returns matching timestamps with surrounding context. Assets must be transcribed first.",
        parameters: .object([
            "query": .init(type: "string", description: "Text to search for in transcripts"),
            "asset_id": .init(type: "string", description: "Optional: search only this asset (omit to search all)"),
            "max_results": .init(type: "number", description: "Maximum results to return (default 10)"),
        ], required: ["query"])
    )

    public static let deleteAsset = AIToolDefinition(
        name: "delete_asset",
        description: "Remove an imported asset from the media library. Cannot delete assets that are currently used by clips on the timeline. Use to clean up unused or duplicate imports.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset to delete"),
        ], required: ["asset_id"])
    )

    public static let setOverlayConfig = AIToolDefinition(
        name: "set_overlay_config",
        description: "Set broadcast overlay configuration. Renders professional graphics over the video: episode title card (0-30s), host name bar, scrolling sponsor/topic ticker, chapter cards, and host intro strip (38-92s). Pass enabled=false to disable.",
        parameters: .object([
            "enabled": .init(type: "boolean", description: "Enable/disable overlay rendering"),
            "episode_title": .init(type: "string", description: "Episode title (uppercase)"),
            "episode_subtitle": .init(type: "string", description: "Episode subtitle"),
            "host_a_name": .init(type: "string", description: "Host A name"),
            "host_a_title": .init(type: "string", description: "Host A title"),
            "host_b_name": .init(type: "string", description: "Host B name"),
            "host_b_title": .init(type: "string", description: "Host B title"),
        ], required: [])
    )

    public static let getOverlayConfig = AIToolDefinition(
        name: "get_overlay_config",
        description: "Get the current broadcast overlay configuration.",
        parameters: .object([:], required: [])
    )

    /// Compact text catalog of all tools — used by PlanGenerator to show Claude
    /// what's available without sending full tool schemas (saves tokens).
    public static var toolCatalog: String {
        allTools.map { "- \($0.name): \($0.description.prefix(100))" }.joined(separator: "\n")
    }

    // MARK: - Content analysis tools (handled specially, not via AIToolResolver)

    public static let getState = AIToolDefinition(
        name: "get_state",
        description: "Get a human-readable summary of the current editor state: tracks, clips, markers, assets, playhead position, duration.",
        parameters: .object([:], required: [])
    )

    public static let autoCut = AIToolDefinition(
        name: "auto_cut",
        description: "Intelligent one-click editing. Analyzes audio + transcript to remove silence, filler words, and re-takes. Three presets: 'gentle' (>2s silence), 'standard' (>0.8s + fillers + retakes), 'aggressive' (>0.3s + hedges + speed up). Requires transcript — transcribe first.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of clip to process (optional, defaults to first clip)"),
            "preset": .init(type: "string", description: "gentle, standard, or aggressive (default: standard)"),
            "dry_run": .init(type: "boolean", description: "Return plan without executing (default: false)"),
        ], required: [])
    )

    public static let analyzeTranscript = AIToolDefinition(
        name: "analyze_transcript",
        description: "Send the FULL transcript to Claude for content comprehension. Identifies real episodes, pre-show chat, rehearsals, planning sections. Run this FIRST before any editing. Transcript-first, tools-second.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
        ], required: ["asset_id"])
    )

    public static let findViralMoments = AIToolDefinition(
        name: "find_viral_moments",
        description: "Find the best viral clip moments in a transcribed podcast or interview (typical span 15–180s per moment). Sends the full diarized transcript to Claude which identifies contrarian claims, surprising stats, emotional peaks, quotable one-liners, and self-contained moments. Returns a ranked list with exact word-level timestamps. Requires a transcript with speaker diarization.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset to analyze"),
            "max_moments": .init(type: "number", description: "Maximum number of viral moments to return (default: 40)"),
            "min_duration_seconds": .init(type: "number", description: "Minimum clip duration in seconds (default: 15)"),
            "max_duration_seconds": .init(type: "number", description: "Maximum clip duration in seconds (default: 180). YouTube Shorts caps at 59s, Reels at 90s — filter downstream by platform."),
        ], required: ["asset_id"])
    )

    public static let uploadShortToLibrary = AIToolDefinition(
        name: "upload_short_to_library",
        description: "Upload an already-exported short (mp4) to the Supabase library so the iOS distribution app can see it. Generates 10 candidate thumbnail frames, writes 5 per-platform caption drafts via Claude, uploads video + thumbnail + frames, and inserts metadata rows. Safe to call multiple times — uses short_id for idempotency.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the source asset"),
            "source_start": .init(type: "number", description: "Clip start time in source seconds"),
            "source_end": .init(type: "number", description: "Clip end time in source seconds"),
            "video_path": .init(type: "string", description: "Absolute path to the exported MP4 file on disk"),
            "label": .init(type: "string", description: "Pill label text (short, 2-5 words)"),
            "hook": .init(type: "string", description: "Original hook quote for this moment"),
            "evergreen_score": .init(type: "number", description: "0-10; default 0"),
            "trending_score": .init(type: "number", description: "0-10; default 0"),
            "platform_fit": .init(type: "array", description: "Platforms this duration fits", items: .init(type: "string")),
            "reasoning": .init(type: "string", description: "Why-viral explanation"),
            "source_asset_name": .init(type: "string", description: "Display name of source asset (e.g. podcast episode title)"),
        ], required: ["asset_id", "source_start", "source_end", "video_path", "label", "hook"])
    )

    public static let getFullTranscript = AIToolDefinition(
        name: "get_full_transcript",
        description: "Get the complete transcript with [MM:SS] timestamps at natural breaks: end of sentences, or pauses longer than ~0.8s (not fixed-interval chunks). Use to READ and understand the content before editing.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
            "start": .init(type: "number", description: "Start time in seconds (optional)"),
            "end": .init(type: "number", description: "End time in seconds (optional)"),
        ], required: ["asset_id"])
    )

    public static let analyzeAudioEnergy = AIToolDefinition(
        name: "analyze_audio_energy",
        description: "Analyze speech energy, silence ratio, and engagement score for a time range. Returns per-second readings or ranked segments.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
            "start": .init(type: "number", description: "Start time (optional)"),
            "end": .init(type: "number", description: "End time (optional)"),
            "segments": .init(type: "number", description: "Number of segments to rank (optional)"),
        ], required: ["asset_id"])
    )

    public static let classifyAudio = AIToolDefinition(
        name: "classify_audio",
        description: "Classify audio segments as live_speech, playback, background, or silence using spectral analysis.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
            "start": .init(type: "number", description: "Start time (optional)"),
            "end": .init(type: "number", description: "End time (optional)"),
        ], required: ["asset_id"])
    )

    public static let detectEpisodes = AIToolDefinition(
        name: "detect_episodes",
        description: "Detect episode boundaries using intro phrases, energy analysis, and meta-talk detection.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
        ], required: ["asset_id"])
    )

    public static let scoreContent = AIToolDefinition(
        name: "score_content",
        description: "Score segments on 5 dimensions: hook strength, retention, emotional arc, completeness, audio quality. Gate-based filtering.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
            "segments": .init(type: "number", description: "Number of segments (default: 10)"),
            "gate_threshold": .init(type: "number", description: "Minimum score to pass (default: 7)"),
        ], required: ["asset_id"])
    )

    public static let segmentTopics = AIToolDefinition(
        name: "segment_topics",
        description: "Break content into coherent topic segments using pauses, speaker changes, and vocabulary shifts.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
            "min_duration": .init(type: "number", description: "Minimum segment duration (default: 15)"),
        ], required: ["asset_id"])
    )

    public static let verifyPlayback = AIToolDefinition(
        name: "verify_playback",
        description: "Verify composition integrity: audio cross-correlation, video perceptual hash, silence detection, duration matching.",
        parameters: .object([
            "mode": .init(type: "string", description: "'quick' or 'thorough' (default: quick)"),
        ], required: [])
    )

    // MARK: - Tool definitions (matching Claude/OpenAI function-calling schema)

    public static let addTrack = AIToolDefinition(
        name: "add_track",
        description: "Add a new track to the timeline. Returns the track ID for use in subsequent operations.",
        parameters: .object([
            "type": .init(type: "string", description: "Track type", enumValues: ["video", "audio", "text", "effect"]),
            "name": .init(type: "string", description: "Track name (optional)"),
            "track_id": .init(type: "string", description: "UUID to assign to the track (optional, auto-generated if omitted)"),
        ], required: ["type"])
    )

    public static let insertClip = AIToolDefinition(
        name: "insert_clip",
        description: "Insert a media asset as a clip on a track at a specific time position",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the media asset to insert"),
            "track_id": .init(type: "string", description: "UUID of the target track"),
            "start_time": .init(type: "number", description: "Timeline position in seconds to insert at"),
            "duration": .init(type: "number", description: "Clip duration in seconds (defaults to asset duration)"),
        ], required: ["asset_id", "track_id", "start_time"])
    )

    public static let moveClip = AIToolDefinition(
        name: "move_clip",
        description: "Move a clip to a new position on the timeline",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to move"),
            "new_start": .init(type: "number", description: "New start time in seconds"),
            "track_id": .init(type: "string", description: "UUID of the target track"),
        ], required: ["clip_id", "new_start", "track_id"])
    )

    public static let deleteClips = AIToolDefinition(
        name: "delete_clips",
        description: "Delete one or more clips from the timeline",
        parameters: .object([
            "clip_ids": .init(type: "array", description: "Array of clip UUIDs to delete", items: .init(type: "string")),
        ], required: ["clip_ids"])
    )

    public static let splitClip = AIToolDefinition(
        name: "split_clip",
        description: "Split a clip into two parts at a specific time",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to split"),
            "at": .init(type: "number", description: "Timeline time in seconds to split at"),
        ], required: ["clip_id", "at"])
    )

    public static let trimClip = AIToolDefinition(
        name: "trim_clip",
        description: "Trim a clip by changing its source in/out points",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to trim"),
            "source_start": .init(type: "number", description: "New source start time in seconds"),
            "source_end": .init(type: "number", description: "New source end time in seconds"),
        ], required: ["clip_id", "source_start", "source_end"])
    )

    public static let setMarker = AIToolDefinition(
        name: "set_marker",
        description: "Add a marker at a specific time on the timeline",
        parameters: .object([
            "time": .init(type: "number", description: "Time in seconds"),
            "label": .init(type: "string", description: "Marker label"),
            "color": .init(type: "string", description: "Marker color as hex string (default #FF0000)"),
        ], required: ["time", "label"])
    )

    public static let removeSilence = AIToolDefinition(
        name: "remove_silence",
        description: "Remove silent segments using precomputed silence ranges on assets (run analysis/transcription that populates silence data). Rebuilds affected clips on the timeline. Cannot be nested inside batch — call as a standalone tool.",
        parameters: .object([
            "clip_ids": .init(type: "array", description: "Clip UUIDs to process (empty = all timeline clips)", items: .init(type: "string")),
            "threshold_db": .init(type: "number", description: "Reserved for future use; detection uses stored ranges"),
            "min_duration": .init(type: "number", description: "Minimum silence duration in seconds to remove (default: 0.5)"),
        ], required: [])
    )

    public static let setClipVolume = AIToolDefinition(
        name: "set_clip_volume",
        description: "Set the audio volume of a clip. 1.0 = normal, 0.0 = silent, 2.0 = double volume",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to adjust"),
            "volume": .init(type: "number", description: "Volume level (0.0 to 2.0, default 1.0)"),
        ], required: ["clip_id", "volume"])
    )

    public static let setClipOpacity = AIToolDefinition(
        name: "set_clip_opacity",
        description: "Set the visual opacity of a clip. 1.0 = fully visible, 0.0 = transparent",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to adjust"),
            "opacity": .init(type: "number", description: "Opacity level (0.0 to 1.0)"),
        ], required: ["clip_id", "opacity"])
    )

    public static let setClipSpeed = AIToolDefinition(
        name: "set_clip_speed",
        description: "Set the playback speed of a clip. Changes clip duration proportionally.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to adjust"),
            "speed": .init(type: "number", description: "Speed multiplier (0.25 = quarter speed, 1.0 = normal, 2.0 = double speed)"),
        ], required: ["clip_id", "speed"])
    )

    public static let muteTrack = AIToolDefinition(
        name: "mute_track",
        description: "Mute or unmute a track",
        parameters: .object([
            "track_id": .init(type: "string", description: "UUID of the track"),
            "muted": .init(type: "boolean", description: "true to mute, false to unmute"),
        ], required: ["track_id", "muted"])
    )

    public static let duplicateClip = AIToolDefinition(
        name: "duplicate_clip",
        description: "Duplicate a clip, placing the copy immediately after the original on the same track",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to duplicate"),
        ], required: ["clip_id"])
    )

    public static let setClipEffect = AIToolDefinition(
        name: "set_clip_effect",
        description: "Apply a visual effect to a clip. Supported types: colorCorrection (brightness/contrast/saturation/temperature), blur (radius), sharpen (sharpness), vignette (intensity/feather).",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "effect_type": .init(type: "string", description: "Effect type: colorCorrection, blur, sharpen, or vignette"),
            "brightness": .init(type: "number", description: "Brightness adjustment (-1 to 1, default 0). Only for colorCorrection."),
            "contrast": .init(type: "number", description: "Contrast (0 to 4, default 1). Only for colorCorrection."),
            "saturation": .init(type: "number", description: "Saturation (0 to 3, default 1). Only for colorCorrection."),
            "temperature": .init(type: "number", description: "Color temperature in Kelvin (2000-10000, default 6500). Only for colorCorrection."),
            "radius": .init(type: "number", description: "Blur radius (0-100, default 10). Only for blur."),
            "sharpness": .init(type: "number", description: "Sharpness (0-2, default 0.4). Only for sharpen."),
            "intensity": .init(type: "number", description: "Vignette intensity (0-1, default 0.5). Only for vignette."),
            "feather": .init(type: "number", description: "Vignette feather/softness (0-1, default 0.7). Only for vignette."),
        ], required: ["clip_id", "effect_type"])
    )

    // MARK: - Track management tools

    public static let removeTrack = AIToolDefinition(
        name: "remove_track",
        description: "Remove an empty track from the timeline. Fails if the track contains clips — delete all clips first.",
        parameters: .object([
            "track_id": .init(type: "string", description: "UUID of the track to remove"),
        ], required: ["track_id"])
    )

    public static let lockTrack = AIToolDefinition(
        name: "lock_track",
        description: "Lock or unlock a track. Locked tracks cannot be edited (no move, trim, split, delete on their clips).",
        parameters: .object([
            "track_id": .init(type: "string", description: "UUID of the track"),
            "locked": .init(type: "boolean", description: "true to lock, false to unlock"),
        ], required: ["track_id", "locked"])
    )

    public static let setTrackVolume = AIToolDefinition(
        name: "set_track_volume",
        description: "Set the volume level of an entire track. Affects all clips on the track during playback/export. Use for background music levels.",
        parameters: .object([
            "track_id": .init(type: "string", description: "UUID of the track"),
            "volume": .init(type: "number", description: "Volume level (0.0 to 2.0, default 1.0)"),
        ], required: ["track_id", "volume"])
    )

    public static let renameClip = AIToolDefinition(
        name: "rename_clip",
        description: "Change a clip's display label for organization.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "label": .init(type: "string", description: "New label text"),
        ], required: ["clip_id", "label"])
    )

    public static let setClipTransition = AIToolDefinition(
        name: "set_clip_transition",
        description: "Set a transition effect on a clip's entry. Types: crossDissolve, fadeToBlack, fadeFromBlack, wipeLeft, wipeRight, none.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "type": .init(type: "string", description: "Transition type"),
            "duration": .init(type: "number", description: "Transition duration in seconds (default 0.5)"),
        ], required: ["clip_id", "type"])
    )

    public static let deleteMarker = AIToolDefinition(
        name: "delete_marker",
        description: "Remove a marker from the timeline.",
        parameters: .object([
            "marker_id": .init(type: "string", description: "UUID of the marker to delete"),
        ], required: ["marker_id"])
    )

    // MARK: - Transform + Roll Trim

    public static let setClipTransform = AIToolDefinition(
        name: "set_clip_transform",
        description: "Set a clip's 2D transform: position, scale, rotation. Use for Ken Burns, picture-in-picture, or repositioning.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "position_x": .init(type: "number", description: "X position offset (default 0)"),
            "position_y": .init(type: "number", description: "Y position offset (default 0)"),
            "scale_x": .init(type: "number", description: "Horizontal scale (1.0 = 100%, default 1)"),
            "scale_y": .init(type: "number", description: "Vertical scale (1.0 = 100%, default 1)"),
            "rotation": .init(type: "number", description: "Rotation in degrees (default 0)"),
        ], required: ["clip_id"])
    )

    public static let setClipKeyframes = AIToolDefinition(
        name: "set_clip_keyframes",
        description: "Animate a clip property over time with keyframes. Tracks: opacity, scaleX, scaleY, positionX, positionY, rotation. Creates smooth animations like Ken Burns, fade in/out, zoom effects.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "track": .init(type: "string", description: "Property to animate: opacity, scaleX, scaleY, positionX, positionY, rotation"),
            "keyframes": .init(type: "string", description: "JSON array of keyframes: [{\"time\": 0, \"value\": 1.0}, {\"time\": 2.5, \"value\": 0.0}]. Time is seconds from clip start. Interpolation: linear (default), easeIn, easeOut, easeInOut, hold."),
        ], required: ["clip_id", "track", "keyframes"])
    )

    public static let rollTrim = AIToolDefinition(
        name: "roll_trim",
        description: "Adjust the boundary between two adjacent clips. Extends one while shortening the other — total duration unchanged.",
        parameters: .object([
            "left_clip_id": .init(type: "string", description: "UUID of the left (outgoing) clip"),
            "right_clip_id": .init(type: "string", description: "UUID of the right (incoming) clip"),
            "new_boundary": .init(type: "number", description: "New boundary time in seconds"),
        ], required: ["left_clip_id", "right_clip_id", "new_boundary"])
    )

    public static let slipClip = AIToolDefinition(
        name: "slip_clip",
        description: "Slip edit: shift which portion of source media is shown within a clip without moving it on the timeline or changing its duration. Positive delta shifts source later, negative shifts earlier.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to slip"),
            "delta": .init(type: "number", description: "Seconds to shift the source window (positive = later, negative = earlier)"),
        ], required: ["clip_id", "delta"])
    )

    public static let rippleTrim = AIToolDefinition(
        name: "ripple_trim",
        description: "Trim a clip's head or tail and shift all subsequent clips on the same track to close/open the gap. For head: positive delta trims more from start. For tail: positive delta extends, negative shortens.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip to trim"),
            "edge": .init(type: "string", description: "Which edge to trim", enumValues: ["head", "tail"]),
            "delta": .init(type: "number", description: "Seconds to adjust (see description for direction)"),
        ], required: ["clip_id", "edge", "delta"])
    )

    // MARK: - Analysis tools (read-only, return data)

    public static let autoReframe = AIToolDefinition(
        name: "auto_reframe",
        description: "Analyze video and generate crop regions for a target aspect ratio (face-aware). When apply is true (default), also sets the first timeline clip’s cropRect for that asset to the average region — disable with apply:false for analysis-only.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset to analyze"),
            "aspect_ratio": .init(type: "string", description: "Target: 9:16 (vertical), 1:1 (square), 4:5 (portrait), 16:9, 21:9"),
            "start": .init(type: "number", description: "Optional source start time in seconds for analysis window"),
            "end": .init(type: "number", description: "Optional source end time in seconds for analysis window"),
            "apply": .init(type: "boolean", description: "If true (default), apply average crop to the timeline clip for this asset"),
        ], required: ["asset_id", "aspect_ratio"])
    )

    public static let detectBeats = AIToolDefinition(
        name: "detect_beats",
        description: "Analyze audio BPM and beat timestamps. Use for syncing cuts to music.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the audio/video asset"),
        ], required: ["asset_id"])
    )

    public static let scoreThumbnails = AIToolDefinition(
        name: "score_thumbnails",
        description: "Find the best thumbnail frames in a video. Scores by face presence, brightness, and sharpness.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the video asset"),
            "count": .init(type: "number", description: "Number of top candidates to return (default 5)"),
        ], required: ["asset_id"])
    )

    public static let suggestBroll = AIToolDefinition(
        name: "suggest_broll",
        description: "Suggest B-roll clips from the media library that match transcript topics.",
        parameters: .object([:], required: [])
    )

    public static let applyPersonMask = AIToolDefinition(
        name: "apply_person_mask",
        description: "Apply AI person segmentation to isolate subjects from background. Uses Vision framework.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the video clip"),
            "action": .init(type: "string", description: "isolate (transparent bg), replace_color, or replace_image"),
        ], required: ["clip_id"])
    )

    public static let trackObject = AIToolDefinition(
        name: "track_object",
        description: "Track an object or face across video frames. Returns per-frame bounding box positions.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the video asset"),
            "track_type": .init(type: "string", description: "face (auto-detect) or region"),
            "start_time": .init(type: "number", description: "Time to start tracking (default 0)"),
        ], required: ["asset_id"])
    )

    public static let voiceCleanup = AIToolDefinition(
        name: "voice_cleanup",
        description: "One-click voice enhancement: noise reduction + EQ + compression. Presets: standard, podcast, interview, presentation, music.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip (optional — applies to all if omitted)"),
            "preset": .init(type: "string", description: "Cleanup preset (default: standard)"),
        ], required: [])
    )

    public static let denoiseAudio = AIToolDefinition(
        name: "denoise_audio",
        description: "Remove background noise from audio using a noise gate.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "threshold_db": .init(type: "number", description: "Noise floor in dB (default -40)"),
        ], required: ["clip_id"])
    )

    public static let denoiseVideo = AIToolDefinition(
        name: "denoise_video",
        description: "Reduce digital noise/grain from video footage using CINoiseReduction.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the video clip"),
            "level": .init(type: "number", description: "Noise reduction level 0-1 (default 0.5)"),
        ], required: ["clip_id"])
    )

    public static let stabilizeVideo = AIToolDefinition(
        name: "stabilize_video",
        description: "Remove camera shake from video using motion analysis.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the video asset"),
            "smoothing": .init(type: "number", description: "Smoothing factor 0-1 (default 0.8, higher = smoother)"),
        ], required: ["asset_id"])
    )

    public static let setCaptionStyle = AIToolDefinition(
        name: "set_caption_style",
        description: "Set the caption/subtitle style. Styles: standard (pill), karaoke (word highlight), bold, outline, gradient.",
        parameters: .object([
            "style": .init(type: "string", description: "Caption style name"),
        ], required: ["style"])
    )

    public static let applyLUT = AIToolDefinition(
        name: "apply_lut",
        description: "Apply a .cube LUT file to a clip for color grading.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "lut_path": .init(type: "string", description: "Path to the .cube LUT file"),
        ], required: ["clip_id", "lut_path"])
    )

    public static let measureLoudness = AIToolDefinition(
        name: "measure_loudness",
        description: "Measure the integrated loudness (LUFS) of an audio/video asset. Use to check levels before normalization.",
        parameters: .object([
            "asset_id": .init(type: "string", description: "UUID of the asset"),
        ], required: ["asset_id"])
    )

    public static let autoDuck = AIToolDefinition(
        name: "auto_duck",
        description: "Automatically duck music volume during speech. Analyzes transcript to find speech regions and lowers music.",
        parameters: .object([
            "music_track_id": .init(type: "string", description: "UUID of the music track"),
            "duck_level": .init(type: "number", description: "Volume during speech 0-1 (default 0.2)"),
        ], required: ["music_track_id"])
    )

    public static let chromaKey = AIToolDefinition(
        name: "chroma_key",
        description: "Remove green screen background from a clip. Apply chroma key based on target color.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the video clip"),
            "target_hue": .init(type: "number", description: "Hue to remove 0-1 (green=0.33, blue=0.66, default 0.33)"),
            "tolerance": .init(type: "number", description: "How much hue variation to include (default 0.1)"),
        ], required: ["clip_id"])
    )

    // MARK: - Compound tools (replace multi-step atomic sequences)

    public static let removeSection = AIToolDefinition(
        name: "remove_section",
        description: "Remove a time range from the timeline and close the gap. Splits at start and end, deletes the middle, then shifts subsequent clips left. Use this instead of manual split+delete+move sequences.",
        parameters: .object([
            "start_time": .init(type: "number", description: "Start of the section to remove (timeline seconds)"),
            "end_time": .init(type: "number", description: "End of the section to remove (timeline seconds)"),
            "track_id": .init(type: "string", description: "Track to operate on (optional — all tracks if omitted)"),
        ], required: ["start_time", "end_time"])
    )

    public static let rippleDelete = AIToolDefinition(
        name: "ripple_delete",
        description: "Delete clips and close the resulting gap by shifting subsequent clips left. Use instead of delete_clips when you want the timeline to contract.",
        parameters: .object([
            "clip_ids": .init(type: "array", description: "UUIDs of clips to delete", items: .init(type: "string")),
        ], required: ["clip_ids"])
    )

    public static let normalizeAudio = AIToolDefinition(
        name: "normalize_audio",
        description: "Adjust volume of multiple clips to a consistent level. Use instead of calling set_clip_volume on each clip individually.",
        parameters: .object([
            "clip_ids": .init(type: "array", description: "Clip UUIDs to normalize (empty = all audio clips)", items: .init(type: "string")),
            "target_volume": .init(type: "number", description: "Target volume level (default 1.0)"),
        ], required: [])
    )

    // MARK: - Clip property tools (parity)

    public static let setClipCrop = AIToolDefinition(
        name: "set_clip_crop",
        description: "Set the crop region of a clip. Values are normalized 0-1 relative to source frame. Use x=0, y=0, width=1, height=1 to clear crop (full frame).",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "x": .init(type: "number", description: "Left edge (0-1)"),
            "y": .init(type: "number", description: "Top edge (0-1)"),
            "width": .init(type: "number", description: "Width (0-1)"),
            "height": .init(type: "number", description: "Height (0-1)"),
        ], required: ["clip_id", "x", "y", "width", "height"])
    )

    public static let setClipBlendMode = AIToolDefinition(
        name: "set_clip_blend_mode",
        description: "Set how a clip composites over clips below it.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "blend_mode": .init(type: "string", description: "Blend mode", enumValues: [
                "normal", "multiply", "screen", "overlay", "darken", "lighten",
                "colorDodge", "colorBurn", "softLight", "hardLight", "difference",
                "exclusion", "hue", "saturation", "color", "luminosity", "add",
            ]),
        ], required: ["clip_id", "blend_mode"])
    )

    public static let removeClipEffect = AIToolDefinition(
        name: "remove_clip_effect",
        description: "Remove a specific effect from a clip by effect ID. Use get_state to find effect IDs.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "effect_id": .init(type: "string", description: "UUID of the effect to remove"),
        ], required: ["clip_id", "effect_id"])
    )

    public static let setClipOverlayPresentation = AIToolDefinition(
        name: "set_clip_overlay_presentation",
        description: "Configure how a clip is presented as an overlay. Set mode to 'pip' for picture-in-picture, 'inline' for normal. Control border, shadow, corner radius, and mask shape.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "mode": .init(type: "string", description: "'inline' (default) or 'pip'", enumValues: ["inline", "pip"]),
            "border_visible": .init(type: "boolean", description: "Show border (default false)"),
            "border_width": .init(type: "number", description: "Border width in points (default 2)"),
            "shadow": .init(type: "string", description: "Shadow style", enumValues: ["none", "light", "medium", "heavy"]),
            "corner_radius": .init(type: "number", description: "Corner radius 0-50 (default 0)"),
            "mask_shape": .init(type: "string", description: "Mask shape", enumValues: ["rectangle", "roundedRect", "circle"]),
        ], required: ["clip_id"])
    )

    public static let applyPiPPreset = AIToolDefinition(
        name: "apply_pip_preset",
        description: "Quick PiP positioning. Sets overlay mode to pip and snaps the clip to a corner of the frame.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "preset": .init(type: "string", description: "Corner position", enumValues: ["topLeft", "topRight", "bottomLeft", "bottomRight"]),
        ], required: ["clip_id", "preset"])
    )

    // MARK: - Track management tools (parity)

    public static let soloTrack = AIToolDefinition(
        name: "solo_track",
        description: "Solo a track (mutes all other tracks). Set soloed=false to unsolo.",
        parameters: .object([
            "track_id": .init(type: "string", description: "UUID of the track"),
            "soloed": .init(type: "boolean", description: "true to solo, false to unsolo (default true)"),
        ], required: ["track_id"])
    )

    public static let renameTrack = AIToolDefinition(
        name: "rename_track",
        description: "Rename a track.",
        parameters: .object([
            "track_id": .init(type: "string", description: "UUID of the track"),
            "name": .init(type: "string", description: "New track name"),
        ], required: ["track_id", "name"])
    )

    public static let reorderTrack = AIToolDefinition(
        name: "reorder_track",
        description: "Move a track to a new position in the stack. Index 0 = bottom of stack.",
        parameters: .object([
            "track_id": .init(type: "string", description: "UUID of the track"),
            "new_index": .init(type: "number", description: "Target position (0-based)"),
        ], required: ["track_id", "new_index"])
    )

    // MARK: - Link + Batch tools

    public static let linkClips = AIToolDefinition(
        name: "link_clips",
        description: "Link or unlink clips so edits propagate together (e.g. video+audio pair). Linked clips move, split, and delete as a group.",
        parameters: .object([
            "clip_ids": .init(type: "array", description: "UUIDs of clips to link/unlink", items: .init(type: "string")),
            "link": .init(type: "boolean", description: "true to link, false to unlink"),
        ], required: ["clip_ids", "link"])
    )

    public static let batch = AIToolDefinition(
        name: "batch",
        description: "Execute multiple tool calls as a single undoable operation. Only intent-backed tools are allowed. Excluded: undo, redo, play_pause, seek, toggle_loop, get_action_log, remove_silence (host-executed; call it separately).",
        parameters: .object([
            "operations": .init(type: "string", description: "JSON array of {\"tool\": \"tool_name\", \"args\": {...}} objects"),
        ], required: ["operations"])
    )

    // MARK: - AppState tools (handled by AIChatController/MCPServer, not AIToolResolver)

    public static let undo = AIToolDefinition(
        name: "undo",
        description: "Undo the last editing action. Returns what was undone.",
        parameters: .object([:])
    )

    public static let redo = AIToolDefinition(
        name: "redo",
        description: "Redo the last undone editing action. Returns what was redone.",
        parameters: .object([:])
    )

    public static let playPause = AIToolDefinition(
        name: "play_pause",
        description: "Control timeline playback. Returns current playback state.",
        parameters: .object([
            "action": .init(type: "string", description: "'play', 'pause', or 'toggle' (default 'toggle')", enumValues: ["play", "pause", "toggle"]),
        ])
    )

    public static let seek = AIToolDefinition(
        name: "seek",
        description: "Move the playhead to a specific time. Accepts seconds as a number, or 'start'/'end' as aliases.",
        parameters: .object([
            "time": .init(type: "string", description: "Time in seconds (number) or 'start'/'end'"),
        ], required: ["time"])
    )

    public static let toggleLoop = AIToolDefinition(
        name: "toggle_loop",
        description: "Enable or disable playback looping.",
        parameters: .object([
            "enabled": .init(type: "boolean", description: "true to enable loop, false to disable"),
        ], required: ["enabled"])
    )

    public static let getActionLog = AIToolDefinition(
        name: "get_action_log",
        description: "Get recent editing actions for debugging or review. Returns timestamp, action name, source (ai/user), and affected IDs.",
        parameters: .object([
            "limit": .init(type: "number", description: "Max entries to return (default 20)"),
        ])
    )

    public static let activateSkill = AIToolDefinition(
        name: "activate_skill",
        description: "Activate a workflow skill for the current task. Returns the full step-by-step workflow with tool usage rules and safety boundaries. Always activate the relevant skill before starting a complex editing workflow. Call again with a different name to switch workflows.",
        parameters: .object([
            "name": .init(type: "string", description: "Skill name from the available_skills list in your instructions"),
        ], required: ["name"])
    )

    // MARK: - Audio processing tools

    public static let applyGate = AIToolDefinition(
        name: "apply_gate",
        description: "Apply a noise gate to an audio clip. Silences audio below the threshold. Use to remove background noise between speech.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip"),
            "threshold_db": .init(type: "number", description: "Gate threshold in dB (default -40)"),
            "attack_ms": .init(type: "number", description: "Attack time in milliseconds (default 0.5)"),
            "release_ms": .init(type: "number", description: "Release time in milliseconds (default 50)"),
        ], required: ["clip_id"])
    )

    public static let applyCompressor = AIToolDefinition(
        name: "apply_compressor",
        description: "Apply dynamic range compression to an audio clip. Reduces volume peaks and evens out loudness.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip"),
            "ratio": .init(type: "number", description: "Compression ratio (default 4)"),
            "attack_ms": .init(type: "number", description: "Attack time in milliseconds (default 5)"),
            "release_ms": .init(type: "number", description: "Release time in milliseconds (default 30)"),
            "threshold_db": .init(type: "number", description: "Threshold in dB (default -20)"),
            "makeup_gain_db": .init(type: "number", description: "Makeup gain in dB (default 3)"),
        ], required: ["clip_id"])
    )

    public static let applyDeEsser = AIToolDefinition(
        name: "apply_de_esser",
        description: "Apply de-esser to reduce sibilance (harsh 's' and 'sh' sounds) in speech.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip"),
            "center_freq_hz": .init(type: "number", description: "Center frequency in Hz (default 5500)"),
            "reduction_db": .init(type: "number", description: "Reduction amount in dB (default -3)"),
        ], required: ["clip_id"])
    )

    public static let applyEQ = AIToolDefinition(
        name: "apply_eq",
        description: "Apply parametric EQ to an audio clip. Specify bands with frequency, gain, Q factor, and filter type.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip"),
            "bands": .init(type: "array", description: "Array of EQ band objects: {freq_hz, gain_db, q, filter_type}. Filter types: peak, lowShelf, highShelf, lowPass, highPass, bandPass, notch.", items: .init(type: "object")),
        ], required: ["clip_id", "bands"])
    )

    public static let applyLimiter = AIToolDefinition(
        name: "apply_limiter",
        description: "Apply a brick-wall limiter to prevent audio clipping. Catches peaks above the threshold.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip"),
            "threshold_db": .init(type: "number", description: "Limiter threshold in dB (default -6)"),
            "attack_ms": .init(type: "number", description: "Attack time in milliseconds (default 1)"),
            "release_ms": .init(type: "number", description: "Release time in milliseconds (default 75)"),
        ], required: ["clip_id"])
    )

    public static let normalizeAudioToLUFS = AIToolDefinition(
        name: "normalize_audio_to_lufs",
        description: "Normalize audio to a target LUFS level. Supports comma-separated clip IDs to normalize multiple clips at once.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip (supports comma-separated for multiple clips)"),
            "target_lufs": .init(type: "number", description: "Target loudness in LUFS (default -16)"),
        ], required: ["clip_id"])
    )

    public static let analyzeAudioSpectrum = AIToolDefinition(
        name: "analyze_audio_spectrum",
        description: "Analyze the frequency spectrum of an audio clip over a time range. Returns frequency distribution data for diagnostics.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip"),
            "start": .init(type: "number", description: "Start time in seconds (default 0)"),
            "end": .init(type: "number", description: "End time in seconds (default: clip end)"),
        ], required: ["clip_id"])
    )

    public static let applySpectralNoiseReduction = AIToolDefinition(
        name: "apply_spectral_noise_reduction",
        description: "Apply spectral noise reduction targeting specific frequencies. Use analyze_audio_spectrum first to identify problem frequencies.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the audio clip"),
            "frequencies_hz": .init(type: "array", description: "Array of frequencies in Hz to reduce", items: .init(type: "number")),
        ], required: ["clip_id", "frequencies_hz"])
    )

    // MARK: - Graphics tools

    public static let addTextOverlay = AIToolDefinition(
        name: "add_text_overlay",
        description: "Add a text overlay to a video clip. Supports positioning, styling, and animation.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the video clip"),
            "text": .init(type: "string", description: "Text to display"),
            "start_time": .init(type: "number", description: "Start time relative to clip in seconds"),
            "duration": .init(type: "number", description: "Duration in seconds"),
            "position_x": .init(type: "number", description: "Horizontal position 0-1 (default 0.5, center)"),
            "position_y": .init(type: "number", description: "Vertical position 0-1 (default 0.8, lower third)"),
            "font_size": .init(type: "number", description: "Font size in points (default 48)"),
            "color_hex": .init(type: "string", description: "Text color as hex (default #FFFFFF)"),
            "background_color_hex": .init(type: "string", description: "Optional background color as hex"),
            "animation": .init(type: "string", description: "Animation type: fadeIn, fadeOut, slideUp, slideDown, typewriter, none (default fadeIn)"),
            "animation_duration_ms": .init(type: "number", description: "Animation duration in milliseconds (default 100)"),
        ], required: ["clip_id", "text", "start_time", "duration"])
    )

    public static let addZoomEffect = AIToolDefinition(
        name: "add_zoom_effect",
        description: "Add a smooth zoom effect to a video clip. Animates from zoom_start to zoom_end over the duration.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the video clip"),
            "start_time": .init(type: "number", description: "Start time relative to clip in seconds"),
            "duration": .init(type: "number", description: "Duration of zoom in seconds"),
            "zoom_start": .init(type: "number", description: "Starting zoom level (default 1.0, no zoom)"),
            "zoom_end": .init(type: "number", description: "Ending zoom level (e.g. 1.5 = 150%)"),
            "center_x": .init(type: "number", description: "Zoom center X 0-1 (default 0.5)"),
            "center_y": .init(type: "number", description: "Zoom center Y 0-1 (default 0.5)"),
        ], required: ["clip_id", "start_time", "duration", "zoom_end"])
    )

    // MARK: - Animation tools

    public static let applySpeedRamp = AIToolDefinition(
        name: "apply_speed_ramp",
        description: "Apply a speed ramp to a clip. Smoothly transitions playback speed from speed_start to speed_end over the time range.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "start_time": .init(type: "number", description: "Start time in seconds"),
            "end_time": .init(type: "number", description: "End time in seconds"),
            "speed_start": .init(type: "number", description: "Starting speed multiplier"),
            "speed_end": .init(type: "number", description: "Ending speed multiplier"),
            "easing": .init(type: "string", description: "Easing curve: linear, easeIn, easeOut, easeInOut (default linear)"),
        ], required: ["clip_id", "start_time", "end_time", "speed_start", "speed_end"])
    )

    // MARK: - Caption tools

    public static let setCaptionTiming = AIToolDefinition(
        name: "set_caption_timing",
        description: "Set caption timing mode. Sync to transcript for automatic timing, or provide manual word timings.",
        parameters: .object([
            "clip_id": .init(type: "string", description: "UUID of the clip"),
            "sync_to_transcript": .init(type: "boolean", description: "Sync caption timing to transcript (default true)"),
            "word_timings": .init(type: "array", description: "Optional manual word timings array", items: .init(type: "object")),
        ], required: ["clip_id"])
    )

    // MARK: - Export tools

    public static let exportVideo = AIToolDefinition(
        name: "export_video",
        description: "Export the current timeline as a video file. Renders all tracks, effects, and overlays.",
        parameters: .object([
            "preset": .init(type: "string", description: "Export quality preset: high, medium, low, proxy (default high)"),
            "filename": .init(type: "string", description: "Output filename (optional, auto-generated if omitted)"),
        ], required: [])
    )

    // MARK: - Image generation tools

    public static let generateThumbnail = AIToolDefinition(
        name: "generate_thumbnail",
        description: "Generate YouTube thumbnails using AI. Composites host photos with styled text and backgrounds. Produces multiple options from different AI models (GPT Image 1.5 + Nano Banana 2). Requires OPENAI_API_KEY and/or GEMINI_API_KEY.",
        parameters: .object([
            "title": .init(type: "string", description: "Episode/video title text for the thumbnail"),
            "description": .init(type: "string", description: "Episode description for AI styling context"),
            "template": .init(type: "string", description: "Overlay template name (e.g. 'technologia_talks') for host info. Loads names, titles, photos from the template."),
            "host_photos": .init(type: "array", description: "Override: paths to host photo files (1-4 photos). If omitted, uses template."),
            "style": .init(type: "string", description: "Visual style: 'bold' (default), 'minimal', 'dramatic', 'vibrant'"),
            "layout": .init(type: "string", description: "Layout: 'split_panel' (default), 'hosts_left', 'centered', 'text_heavy'"),
            "prompt": .init(type: "string", description: "Override: skip AI prompt generation, use this prompt directly for image generation"),
            "count": .init(type: "number", description: "Images per provider (default: 2, so 4 total with both providers)"),
            "provider": .init(type: "string", description: "Provider: 'both' (default), 'openai', 'gemini'"),
        ], required: ["title"])
    )

    public static let generateCarousel = AIToolDefinition(
        name: "generate_carousel",
        description: "Generate Instagram carousel slides (1080x1080) using AI. Each slide gets a styled image with text overlay. Uses Claude for prompt generation, then GPT Image 1.5 and/or Nano Banana 2.",
        parameters: .object([
            "title": .init(type: "string", description: "Carousel title (consistent branding across slides)"),
            "slides": .init(type: "array", description: "Array of slide objects with 'text' (required) and 'image_description' (optional)"),
            "template": .init(type: "string", description: "Overlay template name for host branding"),
            "style": .init(type: "string", description: "Visual style: 'bold' (default), 'minimal', 'dramatic', 'vibrant'"),
            "provider": .init(type: "string", description: "Provider: 'both' (default), 'openai', 'gemini'"),
            "count_per_slide": .init(type: "number", description: "Images per provider per slide (default: 1)"),
        ], required: ["title", "slides"])
    )
}

// MARK: - AIToolDefinition (JSON Schema compatible)

public struct AIToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: ParameterSchema

    public init(name: String, description: String, parameters: ParameterSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public struct ParameterSchema: Codable, Sendable {
        public let type: String
        public let properties: [String: Property]?
        public let required: [String]?
        public let items: Property?

        public init(type: String, properties: [String: Property]?, required: [String]?, items: Property?) {
            self.type = type
            self.properties = properties
            self.required = required
            self.items = items
        }

        public final class Property: Codable, Sendable {
            public let type: String
            public let description: String?
            public let enumValues: [String]?
            public let items: Property?

            enum CodingKeys: String, CodingKey {
                case type, description, items
                case enumValues = "enum"
            }

            public init(type: String, description: String? = nil, enumValues: [String]? = nil, items: Property? = nil) {
                self.type = type
                self.description = description
                self.enumValues = enumValues
                self.items = items
            }
        }

        public static func object(_ properties: [String: Property], required: [String] = []) -> ParameterSchema {
            ParameterSchema(type: "object", properties: properties, required: required, items: nil)
        }
    }
}

// MARK: - AIToolResolver (tool call arguments → EditorIntents)

public struct AIToolResolver: Sendable {

    public init() {}

    /// Resolve an AI tool call into EditorIntents.
    @MainActor
    public func resolve(toolName: String, arguments: [String: Any], assets: [MediaAsset] = []) throws -> [EditorIntent] {
        switch toolName {
        case "add_track":
            let typeStr = arguments["type"] as? String ?? "video"
            let name = arguments["name"] as? String ?? typeStr.capitalized
            guard let trackType = TrackType(rawValue: typeStr) else {
                throw AIToolError.invalidArgument("Unknown track type: \(typeStr)")
            }
            // Use AI-provided ID if given, so subsequent tool calls can reference it
            let trackID: UUID
            if let idStr = arguments["track_id"] as? String, let id = UUID(uuidString: idStr) {
                trackID = id
            } else {
                trackID = UUID()
            }
            return [.addTrack(track: Track(id: trackID, name: name, type: trackType))]

        case "insert_clip":
            guard let assetIDStr = arguments["asset_id"] as? String, let assetID = UUID(uuidString: assetIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid asset_id")
            }
            // Resolve track: try exact ID, then fall back to last track of matching type
            let trackID: UUID
            if let trackIDStr = arguments["track_id"] as? String, let id = UUID(uuidString: trackIDStr) {
                trackID = id
            } else {
                throw AIToolError.invalidArgument("Missing track_id")
            }
            let startTime = (arguments["start_time"] as? Double) ?? 0
            // Look up real asset duration, fall back to explicit duration param
            let assetDuration = assets.first(where: { $0.id == assetID })?.duration
            let duration = (arguments["duration"] as? Double) ?? assetDuration ?? 5

            let clip = Clip(
                assetID: assetID,
                timelineRange: TimeRange(start: startTime, duration: duration),
                sourceRange: TimeRange(start: 0, duration: duration),
                metadata: ClipMetadata(label: assets.first(where: { $0.id == assetID })?.name)
            )
            return [.insertClip(clip: clip, trackID: trackID)]

        case "move_clip":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let newStart = arguments["new_start"] as? Double else {
                throw AIToolError.invalidArgument("Missing new_start")
            }
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid track_id")
            }
            return [.moveClip(clipID: clipID, newStart: newStart, trackID: trackID)]

        case "delete_clips":
            guard let idStrings = arguments["clip_ids"] as? [String] else {
                throw AIToolError.invalidArgument("Missing clip_ids array")
            }
            let ids = idStrings.compactMap { UUID(uuidString: $0) }
            guard !ids.isEmpty else { throw AIToolError.invalidArgument("No valid clip IDs") }
            return [.deleteClips(clipIDs: ids)]

        case "split_clip":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let at = arguments["at"] as? Double else {
                throw AIToolError.invalidArgument("Missing split time")
            }
            return [.splitClip(clipID: clipID, at: at)]

        case "trim_clip":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let start = (arguments["source_start"] as? Double) ?? (arguments["start"] as? Double),
                  let end = (arguments["source_end"] as? Double) ?? (arguments["end"] as? Double) else {
                throw AIToolError.invalidArgument("Missing source_start/source_end")
            }
            return [.trimClip(clipID: clipID, newSourceRange: TimeRange(start: start, end: end))]

        case "set_marker":
            guard let time = arguments["time"] as? Double else {
                throw AIToolError.invalidArgument("Missing time")
            }
            let label = arguments["label"] as? String ?? ""
            let color = arguments["color"] as? String ?? "#FF0000"
            return [.setMarker(at: time, label: label, color: color)]

        case "remove_silence":
            // Handled upstream in AIChatController (needs AppState)
            return []

        case "set_clip_volume":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let volume = (arguments["volume"] as? Double) ?? 1.0
            return [.setClipVolume(clipID: clipID, volume: volume)]

        case "set_clip_opacity":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let opacity = (arguments["opacity"] as? Double) ?? 1.0
            return [.setClipOpacity(clipID: clipID, opacity: opacity)]

        case "set_clip_speed":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let speed = (arguments["speed"] as? Double) ?? 1.0
            return [.setClipSpeed(clipID: clipID, speed: speed)]

        case "mute_track":
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing track_id")
            }
            let muted = (arguments["muted"] as? Bool) ?? true
            return [.muteTrack(trackID: trackID, muted: muted)]

        case "duplicate_clip":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            return [.duplicateClip(clipID: clipID)]

        case "set_clip_effect":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let effectType = (arguments["effect_type"] as? String) ?? (arguments["effect"] as? String) ?? "colorCorrection"
            if effectType == "none" || effectType == "clear" {
                // Clear all effects
                return [.replacePrimaryClipEffect(clipID: clipID, effect: EffectInstance(type: "_none", parameters: [:]))]
            }
            let effect: EffectInstance
            switch effectType {
            case "colorCorrection":
                effect = .colorCorrection(
                    brightness: (arguments["brightness"] as? Double) ?? 0,
                    contrast: (arguments["contrast"] as? Double) ?? 1,
                    saturation: (arguments["saturation"] as? Double) ?? 1,
                    temperature: (arguments["temperature"] as? Double) ?? 6500
                )
            case "blur":
                effect = EffectInstance(type: "blur", parameters: ["radius": (arguments["radius"] as? Double) ?? 10])
            case "sharpen":
                effect = EffectInstance(type: "sharpen", parameters: ["sharpness": (arguments["sharpness"] as? Double) ?? 0.4])
            case "vignette":
                effect = .vignette(
                    intensity: (arguments["intensity"] as? Double) ?? 0.5,
                    feather: (arguments["feather"] as? Double) ?? 0.7
                )
            default:
                throw AIToolError.invalidArgument("Unknown effect type: \(effectType)")
            }
            return [.replacePrimaryClipEffect(clipID: clipID, effect: effect)]

        case "set_clip_transform":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let uniformScale = (arguments["scale"] as? Double) ?? 1.0
            let transform = Transform2D(
                positionX: (arguments["position_x"] as? Double) ?? (arguments["x"] as? Double) ?? 0,
                positionY: (arguments["position_y"] as? Double) ?? (arguments["y"] as? Double) ?? 0,
                scaleX: (arguments["scale_x"] as? Double) ?? uniformScale,
                scaleY: (arguments["scale_y"] as? Double) ?? uniformScale,
                rotation: (arguments["rotation"] as? Double) ?? 0
            )
            return [.setClipTransform(clipID: clipID, transform: transform)]

        case "set_clip_keyframes":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr),
                  let track = arguments["track"] as? String,
                  let kfJSON = arguments["keyframes"] as? String else {
                throw AIToolError.invalidArgument("Missing clip_id, track, or keyframes")
            }
            guard let data = kfJSON.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AIToolError.invalidArgument("keyframes must be a valid JSON array")
            }
            let keyframes: [Keyframe] = arr.compactMap { entry in
                guard let time = entry["time"] as? Double, let value = entry["value"] as? Double else { return nil }
                let interpStr = entry["interpolation"] as? String ?? "linear"
                let interp = KeyframeInterpolation(rawValue: interpStr) ?? .linear
                return Keyframe(time: time, value: value, interpolation: interp)
            }
            return [.setClipKeyframes(clipID: clipID, track: track, keyframes: keyframes)]

        case "denoise_video":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let level = (arguments["level"] as? Double) ?? 0.5
            return [.replacePrimaryClipEffect(clipID: clipID, effect: .videoDenoise(level: level))]

        case "apply_lut":
            guard let clipIDStr = arguments["clip_id"] as? String,
                  let clipID = UUID(uuidString: clipIDStr),
                  let lutPath = arguments["lut_path"] as? String,
                  !lutPath.isEmpty else {
                throw AIToolError.invalidArgument("Missing clip_id or lut_path")
            }
            return [.replacePrimaryClipEffect(clipID: clipID, effect: .lut(path: lutPath))]

        case "chroma_key":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            // Accept "color" as string ("green"=0.33, "blue"=0.66) or "target_hue" as double
            let targetHue: Double
            if let hue = arguments["target_hue"] as? Double {
                targetHue = hue
            } else if let color = arguments["color"] as? String {
                switch color.lowercased() {
                case "green": targetHue = 0.33
                case "blue": targetHue = 0.66
                case "red": targetHue = 0.0
                default: targetHue = 0.33
                }
            } else {
                targetHue = 0.33
            }
            let tolerance = (arguments["tolerance"] as? Double) ?? (arguments["threshold"] as? Double) ?? 0.1
            return [.replacePrimaryClipEffect(
                clipID: clipID,
                effect: .chromaKey(targetHue: targetHue, tolerance: tolerance)
            )]

        case "roll_trim":
            guard let leftStr = arguments["left_clip_id"] as? String, let leftID = UUID(uuidString: leftStr),
                  let rightStr = arguments["right_clip_id"] as? String, let rightID = UUID(uuidString: rightStr),
                  let boundary = arguments["new_boundary"] as? Double else {
                throw AIToolError.invalidArgument("Missing left_clip_id, right_clip_id, or new_boundary")
            }
            return [.rollTrim(leftClipID: leftID, rightClipID: rightID, newBoundary: boundary)]

        case "slip_clip":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let delta = arguments["delta"] as? Double else {
                throw AIToolError.invalidArgument("Missing delta")
            }
            return [.slipClip(clipID: clipID, delta: delta)]

        case "ripple_trim":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let edgeStr = arguments["edge"] as? String, let edge = TrimEdge(rawValue: edgeStr) else {
                throw AIToolError.invalidArgument("Missing or invalid edge (must be 'head' or 'tail')")
            }
            guard let delta = arguments["delta"] as? Double else {
                throw AIToolError.invalidArgument("Missing delta")
            }
            return [.rippleTrim(clipID: clipID, edge: edge, delta: delta)]

        case "remove_section":
            guard let start = arguments["start_time"] as? Double,
                  let end = arguments["end_time"] as? Double else {
                throw AIToolError.invalidArgument("Missing start_time or end_time")
            }
            return [.removeSection(startTime: start, endTime: end)]

        case "ripple_delete":
            guard let idStrings = arguments["clip_ids"] as? [String] else {
                throw AIToolError.invalidArgument("Missing clip_ids array")
            }
            let ids = idStrings.compactMap { UUID(uuidString: $0) }
            guard !ids.isEmpty else {
                throw AIToolError.invalidArgument("No valid clip IDs in clip_ids")
            }
            return [.rippleDeleteClips(clipIDs: ids)]

        // Analysis tools — handled upstream in AIChatController/MCPServer (need AppState)
        // Return empty intents — the caller handles these before reaching the resolver.
        case "auto_reframe", "detect_beats", "score_thumbnails", "suggest_broll",
             "apply_person_mask", "track_object", "voice_cleanup", "denoise_audio",
             "stabilize_video", "set_caption_style", "measure_loudness", "auto_duck":
            return []

        case "remove_track":
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing track_id")
            }
            return [.removeTrack(trackID: trackID)]

        case "lock_track":
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing track_id")
            }
            let locked = (arguments["locked"] as? Bool) ?? true
            return [.lockTrack(trackID: trackID, locked: locked)]

        case "set_track_volume":
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing track_id")
            }
            let volume = (arguments["volume"] as? Double) ?? 1.0
            return [.setTrackVolume(trackID: trackID, volume: volume)]

        case "rename_clip":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let label = (arguments["label"] as? String) ?? ""
            return [.renameClip(clipID: clipID, label: label)]

        case "set_clip_transition":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let typeStr = (arguments["type"] as? String) ?? "none"
            let transitionType = TransitionType(rawValue: typeStr) ?? .none
            let duration = (arguments["duration"] as? Double) ?? 0.5
            return [.setClipTransition(clipID: clipID, transition: ClipTransition(type: transitionType, duration: duration))]

        case "delete_marker":
            guard let markerIDStr = arguments["marker_id"] as? String, let markerID = UUID(uuidString: markerIDStr) else {
                throw AIToolError.invalidArgument("Missing marker_id")
            }
            return [.deleteMarker(markerID: markerID)]

        case "set_overlay_config":
            let enabled = arguments["enabled"] as? Bool ?? true
            let config = BroadcastOverlayConfig(
                isEnabled: enabled,
                episodeTitle: arguments["episode_title"] as? String ?? "",
                episodeSubtitle: arguments["episode_subtitle"] as? String ?? "",
                hostA: HostInfo(
                    name: arguments["host_a_name"] as? String ?? "",
                    title: arguments["host_a_title"] as? String ?? ""
                ),
                hostB: HostInfo(
                    name: arguments["host_b_name"] as? String ?? "",
                    title: arguments["host_b_title"] as? String ?? ""
                )
            )
            return [.setBroadcastOverlay(config: config)]

        case "get_overlay_config":
            // Read-only — handled by AIChatController, not via intents
            return []

        case "set_clip_crop":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let x = arguments["x"] as? Double,
                  let y = arguments["y"] as? Double,
                  let width = arguments["width"] as? Double,
                  let height = arguments["height"] as? Double else {
                throw AIToolError.invalidArgument("Missing x, y, width, or height")
            }
            return [.setClipCrop(clipID: clipID, cropRect: CropRect(x: x, y: y, width: width, height: height))]

        case "set_clip_blend_mode":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let modeStr = arguments["blend_mode"] as? String, let mode = BlendMode(rawValue: modeStr) else {
                throw AIToolError.invalidArgument("Missing or invalid blend_mode")
            }
            return [.setClipBlendMode(clipID: clipID, blendMode: mode)]

        case "remove_clip_effect":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let effectIDStr = arguments["effect_id"] as? String, let effectID = UUID(uuidString: effectIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid effect_id")
            }
            return [.removeClipEffect(clipID: clipID, effectID: effectID)]

        case "set_clip_overlay_presentation":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            let modeStr = (arguments["mode"] as? String) ?? "inline"
            let mode = OverlayPresentationMode(rawValue: modeStr) ?? .inline
            let borderVisible = (arguments["border_visible"] as? Bool) ?? false
            let borderWidth = (arguments["border_width"] as? Double) ?? 2.0
            let shadowStr = (arguments["shadow"] as? String) ?? "none"
            let shadow = OverlayShadowStyle(rawValue: shadowStr) ?? .none
            let cornerRadius = (arguments["corner_radius"] as? Double) ?? 0
            let maskStr = (arguments["mask_shape"] as? String) ?? "rectangle"
            let maskShape = OverlayMaskShape(rawValue: maskStr) ?? .rectangle
            let presentation = OverlayPresentation(
                mode: mode,
                border: borderVisible ? .visible(width: borderWidth) : .hidden,
                shadow: shadow,
                cornerRadius: cornerRadius,
                maskShape: maskShape
            )
            return [.setClipOverlayPresentation(clipID: clipID, presentation: presentation)]

        case "apply_pip_preset":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid clip_id")
            }
            guard let presetStr = arguments["preset"] as? String, let preset = OverlayPiPPreset(rawValue: presetStr) else {
                throw AIToolError.invalidArgument("Missing or invalid preset (topLeft, topRight, bottomLeft, bottomRight)")
            }
            return [.applyClipPiPPreset(clipID: clipID, preset: preset)]

        case "solo_track":
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid track_id")
            }
            let soloed = (arguments["soloed"] as? Bool) ?? true
            return [.soloTrack(trackID: trackID, soloed: soloed)]

        case "rename_track":
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid track_id")
            }
            guard let name = arguments["name"] as? String, !name.isEmpty else {
                throw AIToolError.invalidArgument("Missing or empty name")
            }
            return [.renameTrack(trackID: trackID, name: name)]

        case "reorder_track":
            guard let trackIDStr = arguments["track_id"] as? String, let trackID = UUID(uuidString: trackIDStr) else {
                throw AIToolError.invalidArgument("Missing or invalid track_id")
            }
            let newIndex: Int
            if let i = arguments["new_index"] as? Int {
                newIndex = i
            } else if let d = arguments["new_index"] as? Double {
                newIndex = Int(d.rounded())
            } else {
                throw AIToolError.invalidArgument("Missing new_index (number)")
            }
            return [.reorderTrack(trackID: trackID, newIndex: newIndex)]

        case "link_clips":
            guard let idStrings = arguments["clip_ids"] as? [String] else {
                throw AIToolError.invalidArgument("Missing clip_ids array")
            }
            let ids = idStrings.compactMap { UUID(uuidString: $0) }
            guard !ids.isEmpty else { throw AIToolError.invalidArgument("No valid clip IDs") }
            guard let link = arguments["link"] as? Bool else {
                throw AIToolError.invalidArgument("Missing link parameter (true/false)")
            }
            return [.linkClips(clipIDs: ids, linkGroupID: link ? UUID() : nil)]

        case "batch":
            guard let opsJSON = arguments["operations"] as? String,
                  let data = opsJSON.data(using: .utf8),
                  let ops = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AIToolError.invalidArgument("operations must be a valid JSON array string")
            }
            let appStateTools: Set<String> = [
                "undo", "redo", "play_pause", "seek", "toggle_loop", "get_action_log",
                "remove_silence",
            ]
            var allIntents: [EditorIntent] = []
            for op in ops {
                guard let toolName = op["tool"] as? String else {
                    throw AIToolError.invalidArgument("Each operation must have a 'tool' field")
                }
                guard !appStateTools.contains(toolName) else {
                    throw AIToolError.invalidArgument("'\(toolName)' cannot be used inside batch")
                }
                let opArgs = op["args"] as? [String: Any] ?? [:]
                let intents = try resolve(toolName: toolName, arguments: opArgs, assets: assets)
                allIntents.append(contentsOf: intents)
            }
            return [.batch(allIntents)]

        // Audio processing tools
        case "apply_gate":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let config = GateConfig(
                thresholdDB: (arguments["threshold_db"] as? Double) ?? -40,
                attackMS: (arguments["attack_ms"] as? Double) ?? 0.5,
                releaseMS: (arguments["release_ms"] as? Double) ?? 50
            )
            return [.applyGate(clipID: clipID, config: config)]

        case "apply_compressor":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let config = CompressorConfig(
                ratio: (arguments["ratio"] as? Double) ?? 4,
                attackMS: (arguments["attack_ms"] as? Double) ?? 5,
                releaseMS: (arguments["release_ms"] as? Double) ?? 30,
                thresholdDB: (arguments["threshold_db"] as? Double) ?? -20,
                makeupGainDB: (arguments["makeup_gain_db"] as? Double) ?? 3
            )
            return [.applyCompressor(clipID: clipID, config: config)]

        case "apply_de_esser":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let config = DeEsserConfig(
                centerFreqHz: (arguments["center_freq_hz"] as? Double) ?? 5500,
                reductionDB: (arguments["reduction_db"] as? Double) ?? -3
            )
            return [.applyDeEsser(clipID: clipID, config: config)]

        case "apply_eq":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            var bands: [EQBand] = []
            if let bandsArray = arguments["bands"] as? [[String: Any]] {
                for b in bandsArray {
                    bands.append(EQBand(
                        freqHz: (b["freq_hz"] as? Double) ?? 1000,
                        gainDB: (b["gain_db"] as? Double) ?? 0,
                        q: (b["q"] as? Double) ?? 1.0,
                        filterType: EQFilterType(rawValue: (b["filter_type"] as? String) ?? "peak") ?? .peak
                    ))
                }
            }
            return [.applyEQ(clipID: clipID, config: EQConfig(bands: bands))]

        case "apply_limiter":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr) else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let config = LimiterConfig(
                thresholdDB: (arguments["threshold_db"] as? Double) ?? -6,
                attackMS: (arguments["attack_ms"] as? Double) ?? 1,
                releaseMS: (arguments["release_ms"] as? Double) ?? 75
            )
            return [.applyLimiter(clipID: clipID, config: config)]

        case "normalize_audio_to_lufs":
            guard let clipIDStr = arguments["clip_id"] as? String else {
                throw AIToolError.invalidArgument("Missing clip_id")
            }
            let targetLUFS = (arguments["target_lufs"] as? Double) ?? -16
            let clipIDs = clipIDStr.split(separator: ",").compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
            if clipIDs.isEmpty { throw AIToolError.invalidArgument("Invalid clip_id") }
            return clipIDs.map { .normalizeLUFS(clipID: $0, targetLUFS: targetLUFS) }

        case "add_text_overlay":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr),
                  let text = arguments["text"] as? String,
                  let startTime = arguments["start_time"] as? Double,
                  let duration = arguments["duration"] as? Double else {
                throw AIToolError.invalidArgument("Missing required parameters")
            }
            let overlay = TextOverlay(
                text: text, startTime: startTime, duration: duration,
                positionX: (arguments["position_x"] as? Double) ?? 0.5,
                positionY: (arguments["position_y"] as? Double) ?? 0.8,
                fontSize: (arguments["font_size"] as? Double) ?? 48,
                colorHex: (arguments["color_hex"] as? String) ?? "#FFFFFF",
                backgroundColorHex: arguments["background_color_hex"] as? String,
                animation: TextAnimation(rawValue: (arguments["animation"] as? String) ?? "fadeIn") ?? .fadeIn,
                animationDurationMS: (arguments["animation_duration_ms"] as? Double) ?? 100
            )
            return [.addTextOverlay(clipID: clipID, overlay: overlay)]

        case "add_zoom_effect":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr),
                  let startTime = arguments["start_time"] as? Double,
                  let duration = arguments["duration"] as? Double,
                  let zoomEnd = arguments["zoom_end"] as? Double else {
                throw AIToolError.invalidArgument("Missing required parameters")
            }
            return [.addZoomEffect(clipID: clipID, startTime: startTime, duration: duration,
                zoomStart: (arguments["zoom_start"] as? Double) ?? 1.0, zoomEnd: zoomEnd,
                centerX: (arguments["center_x"] as? Double) ?? 0.5, centerY: (arguments["center_y"] as? Double) ?? 0.5)]

        case "apply_speed_ramp":
            guard let clipIDStr = arguments["clip_id"] as? String, let clipID = UUID(uuidString: clipIDStr),
                  let startTime = arguments["start_time"] as? Double,
                  let endTime = arguments["end_time"] as? Double,
                  let speedStart = arguments["speed_start"] as? Double,
                  let speedEnd = arguments["speed_end"] as? Double else {
                throw AIToolError.invalidArgument("Missing required parameters")
            }
            let easing = KeyframeInterpolation(rawValue: (arguments["easing"] as? String) ?? "linear") ?? .linear
            return [.applySpeedRamp(clipID: clipID, startTime: startTime, endTime: endTime, speedStart: speedStart, speedEnd: speedEnd, easing: easing)]

        // Analysis/server-handled tools — return empty intents
        case "analyze_audio_spectrum", "apply_spectral_noise_reduction", "set_caption_timing", "export_video":
            return []

        // AppState tools — handled upstream in AIChatController/MCPServer, not via intents
        case "undo", "redo", "play_pause", "seek", "toggle_loop", "get_action_log", "activate_skill":
            return []

        default:
            throw AIToolError.unknownTool(toolName)
        }
    }
}

// MARK: - AIToolError

public enum AIToolError: Error, LocalizedError {
    case unknownTool(String)
    case invalidArgument(String)
    case notYetImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .invalidArgument(let msg): "Invalid argument: \(msg)"
        case .notYetImplemented(let msg): msg
        }
    }
}
