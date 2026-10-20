import Foundation
@testable import KpubCore
import XCTest

final class ModelsTests: XCTestCase {
    func testDecodeSerial() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "serial", withExtension: "json", subdirectory: "Fixtures"))
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(contentsOf: url)).item
        XCTAssertEqual(item.title, "Тестовый сериал")
        XCTAssertEqual(item.originalTitle, "Test Show")
        XCTAssertTrue(item.isSerial)
        XCTAssertEqual(item.kinopoiskRating, 7.5)
        let ep = try XCTUnwrap(item.seasons?.first?.episodes.first)
        XCTAssertEqual(ep.audios.map(\.index), [1, 2], "дорожки сортируются по index")
        XCTAssertEqual(ep.audios[0].displayName, "Многоголосый · LostFilm · Русский · 5.1 AC3")
        XCTAssertEqual(ep.subtitles[1].shift, 1.5)
        XCTAssertTrue(ep.subtitles[1].forced)
        XCTAssertEqual(item.seasons?.first?.episodes[1].duration, 2650)

        // Авто-качество под 720p берёт 720p, под оригинал без пережатия — 1080p.
        let s720 = EncodePreset.default.settings
        XCTAssertEqual(DownloadRequest.pickFile(ep.files, preferredHeight: 0, settings: s720)?.quality, "720p")
        XCTAssertEqual(DownloadRequest.pickFile(ep.files, preferredHeight: 0, settings: EncodeSettings(videoCodec: .copy, maxHeight: 0))?.quality, "1080p")

        let jobs = DownloadRequest.makeJobs(
            item: item, entries: [.init(season: 1, video: ep)], preferredHeight: 0,
            audio: [ep.audios[1], ep.audios[0]], subtitles: [ep.subtitles[0]], settings: s720,
            root: URL(fileURLWithPath: "/tmp/kp")
        )
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].audio.map(\.streamPosition), [1, 0], "порядок выбора сохраняется, первая — по умолчанию")
        XCTAssertEqual(jobs[0].outputPath, "/tmp/kp/Сериалы/Тестовый сериал/Season 01/Тестовый сериал - S01E01 - Pilot.mp4")
        XCTAssertEqual(jobs[0].sourceKind, .file)
        XCTAssertEqual(jobs[0].sourceURL?.absoluteString, "https://cdn.example/720.mp4")
        XCTAssertEqual(jobs[0].audio.map(\.apiIndex), [2, 1])
    }

    func testSubtitleCP1251IsConvertedToUTF8() {
        let cp1251 = "1\n00:00:01,000 --> 00:00:02,000\nПривет\n".data(using: .windowsCP1251)!
        XCTAssertEqual(String(data: SubtitleFetcher.normalizeEncoding(cp1251), encoding: .utf8)?.contains("Привет"), true)
    }
}

/// Прогон настоящего ffmpeg на синтетическом файле: две озвучки + srt → HEVC 480p MP4.
final class TranscodeTests: XCTestCase {
    func testTranscodeSelectsTracksAndEmbedsSubtitles() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("ffmpeg не установлен") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.mp4").path
        let make = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1920x800:rate=25:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=3",
            "-map", "0", "-map", "1", "-map", "2", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-ac:a:1", "6",
            source,
        ])
        XCTAssertEqual(make.status, 0, make.stderr)

        let srt = dir.appendingPathComponent("sub.srt").path
        try "1\n00:00:00,500 --> 00:00:02,000\nПривет\n".write(toFile: srt, atomically: true, encoding: .utf8)

        let probe = try await FFprobe.probe(tools, input: source)
        XCTAssertEqual(probe.audio.count, 2)
        let audio = DownloadManager.mapAudio([
            SelectedAudio(streamPosition: 1, language: "eng", title: "Original"),
            SelectedAudio(streamPosition: 0, language: "rus", title: "Дубляж"),
        ], sourceCount: probe.audio.count)

        let output = dir.appendingPathComponent("out.mp4").path
        let plan = TranscodePlan(
            input: source, audio: audio,
            subtitles: [.init(path: srt, language: "rus", title: "Русский", forced: false, shift: 0.5)],
            settings: EncodePreset.all.first { $0.id == "tiny480" }!.settings,
            sourceVideoCodec: probe.video?.codecName, title: "Тест", output: output,
            encoders: await tools.availableEncoders()
        )
        let fractions = Fractions()
        try await FFmpegRunner.run(tools, plan: plan, duration: 3) { fractions.append($0.fraction) }
        XCTAssertEqual(fractions.last, 1)

        let result = try await FFprobe.probe(tools, input: output)
        XCTAssertEqual(result.video?.codecName, "hevc")
        XCTAssertEqual(result.video?.width, 852)  // 1920x800 вписано в рамку 853x480
        XCTAssertEqual(result.audio.map(\.language), ["eng", "rus"])
        XCTAssertEqual(result.audio.map(\.channels), [2, 2])
        XCTAssertEqual(result.subtitles.first?.codecName, "mov_text")
        XCTAssertEqual(result.subtitles.first?.language, "rus")

        // Повторное пережатие готового файла: все дорожки и встроенные субтитры сохраняются, MP4 → MKV.
        let again = dir.appendingPathComponent("again.mkv").path
        var smaller = EncodeSettings(videoCodec: .hevcHardware, maxHeight: 360, videoBitrateKbps: 300, audioMode: .aacStereo, audioBitrateKbps: 64)
        smaller.container = .mkv
        let replan = TranscodePlan(
            input: output,
            audio: result.audio.enumerated().map { .init(source: .main($0.offset), language: $0.element.language, title: $0.element.title) },
            subtitles: result.subtitles.enumerated().map { .init(embeddedIndex: $0.offset, language: $0.element.language, title: $0.element.title) },
            settings: smaller, sourceVideoCodec: result.video?.codecName, title: "Тест", output: again,
            encoders: await tools.availableEncoders()
        )
        try await FFmpegRunner.run(tools, plan: replan, duration: 3) { _ in }
        let redone = try await FFprobe.probe(tools, input: again)
        XCTAssertEqual(redone.video?.width, 640)  // 2.4:1 вписано в рамку 640x360
        XCTAssertEqual(redone.audio.map(\.language), ["eng", "rus"])
        XCTAssertEqual(redone.audio.map(\.title), ["Original", "Дубляж"])
        XCTAssertEqual(redone.subtitles.first?.codecName, "subrip")
        XCTAssertEqual(redone.subtitles.first?.language, "rus")
    }
}

final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var last: Double? { lock.lock(); defer { lock.unlock() }; return values.last }
}

/// HLS как у kino.pub (hls4): варианты 720p/480p + озвучки "01. …", "02. …" отдельными плейлистами.
final class HLSPipelineTests: XCTestCase {
    func testMasterParsingAndPicking() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio1080",NAME="01. Дубляж. Пифагор (RUS)",LANGUAGE="rus",URI="a1.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio1080",NAME="01. Дубляж. Пифагор (RUS) AC3",LANGUAGE="rus",URI="a1ac3.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio1080",NAME="10. Original (ENG)",LANGUAGE="eng",URI="a10.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x800,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio1080"
        v1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x534,CODECS="avc1.64001f,mp4a.40.2",AUDIO="audio1080"
        v720.m3u8
        """
        let master = HLSMaster.parse(text, baseURL: URL(string: "https://cdn.example/hls4/x/master.m3u8")!)
        XCTAssertEqual(master.variants.map(\.qualityClass), [1080, 720])
        let v = master.pickVariant(preferredHeight: 720)
        XCTAssertEqual(v?.url.absoluteString, "https://cdn.example/hls4/x/v720.m3u8")
        XCTAssertEqual(master.pickVariant(preferredHeight: 480)?.qualityClass, 720, "ниже нет — берём минимальный")
        let picked = master.pickAudio(for: v!, apiIndices: [10, 1], positions: [1, 0], preferAC3: false)
        XCTAssertEqual(picked.map(\.rendition.name), ["10. Original (ENG)", "01. Дубляж. Пифагор (RUS)"])
        XCTAssertEqual(picked.map(\.selection), [0, 1])
        XCTAssertEqual(master.pickAudio(for: v!, apiIndices: [1], positions: [0], preferAC3: true).first?.rendition.name,
                       "01. Дубляж. Пифагор (RUS) AC3")
    }

    func testDownloadAndMuxSeparateTracks() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("ffmpeg не установлен") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kp-hls-\(UUID().uuidString)")
        let served = root.appendingPathComponent("served")
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let make = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25:duration=6",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=6",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=6",
            "-filter_complex", "[0:v]split=2[a][b];[b]scale=854:480[c]",
            "-map", "[a]", "-map", "[c]", "-map", "1:a", "-map", "2:a",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-c:a", "aac",
            "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod", "-master_pl_name", "master.m3u8",
            "-var_stream_map", "v:0,agroup:aud v:1,agroup:aud a:0,agroup:aud,language:rus a:1,agroup:aud,language:eng",
            served.appendingPathComponent("s_%v.m3u8").path,
        ])
        XCTAssertEqual(make.status, 0, make.stderr)
        let masterPath = served.appendingPathComponent("master.m3u8")
        var master = try String(contentsOf: masterPath, encoding: .utf8)
        master = master.replacingOccurrences(of: "NAME=\"audio_0\"", with: "NAME=\"01. Многоголосый (RUS)\"")
            .replacingOccurrences(of: "NAME=\"audio_1\"", with: "NAME=\"02. Original (ENG)\"")
            .replacingOccurrences(of: "NAME=\"audio_2\"", with: "NAME=\"01. Многоголосый (RUS)\"")
            .replacingOccurrences(of: "NAME=\"audio_3\"", with: "NAME=\"02. Original (ENG)\"")
        try master.write(to: masterPath, atomically: true, encoding: .utf8)

        let port = Int.random(in: 20000...40000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", served.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        let masterURL = URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
        var text = ""
        for _ in 0..<50 {
            if let t = try? await HLSDownloader.fetchText(masterURL) { text = t; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let parsed = HLSMaster.parse(text, baseURL: masterURL)
        let variant = try XCTUnwrap(parsed.pickVariant(preferredHeight: 480))
        XCTAssertEqual(variant.width, 854)
        let audio = parsed.pickAudio(for: variant, apiIndices: [2, 1], positions: [1, 0], preferAC3: false)
        XCTAssertEqual(audio.count, 2)

        var tracks = [HLSDownloader.Track(name: "video", playlistURL: variant.url, bandwidth: variant.bandwidth)]
        for (k, a) in audio.enumerated() {
            tracks.append(.init(name: "audio_\(k)", playlistURL: a.rendition.url!, bandwidth: 128_000))
        }
        let work = root.appendingPathComponent("work")
        let fractions = Fractions()
        let playlists = try await HLSDownloader.download(tracks: tracks, into: work) { fractions.append($0.fraction ?? 0) }
        XCTAssertEqual(Set(playlists.keys), ["video", "audio_0", "audio_1"])
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.001)

        // Повторный вызов ничего не качает заново (докачка).
        _ = try await HLSDownloader.download(tracks: tracks, into: work) { _ in }

        let videoProbe = try await FFprobe.probe(tools, input: playlists["video"]!.path, isHLSPlaylist: true)
        var planAudio: [TranscodePlan.Audio] = []
        for (k, lang) in ["eng", "rus"].enumerated() {
            let path = playlists["audio_\(k)"]!.path
            let p = try await FFprobe.probe(tools, input: path, isHLSPlaylist: true)
            planAudio.append(.init(source: .separate(.init(path: path, isHLSPlaylist: true, startTime: p.startTime ?? 0)),
                                   language: lang, title: lang))
        }
        let output = root.appendingPathComponent("out.mp4").path
        let plan = TranscodePlan(
            input: .init(path: playlists["video"]!.path, isHLSPlaylist: true, startTime: videoProbe.startTime ?? 0),
            audio: planAudio, subtitles: [], settings: EncodePreset.all.first { $0.id == "original" }!.settings,
            sourceVideoCodec: videoProbe.video?.codecName, title: nil, output: output, encoders: []
        )
        try await FFmpegRunner.run(tools, plan: plan, duration: 6) { _ in }

        let result = try await FFprobe.probe(tools, input: output)
        XCTAssertEqual(result.video?.height, 480)
        XCTAssertEqual(result.audio.map(\.language), ["eng", "rus"])
        XCTAssertEqual(result.duration ?? 0, 6, accuracy: 0.2)
        // Синхронизация: видео и звук начинаются почти одновременно.
        let starts = try await ProcessRunner.run(tools.ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=start_time", "-of", "csv=p=0", output,
        ]).stdout.split(separator: "\n").compactMap { Double($0) }
        XCTAssertEqual(starts.count, 3)
        XCTAssertLessThan((starts.max() ?? 0) - (starts.min() ?? 0), 0.05, "\(starts)")
    }
}

/// Реальный ответ /v1/items/{id} и структура hls4-манифеста kino.pub (токены вырезаны).
final class RealResponseTests: XCTestCase {
    func testRealSerialToHLSJob() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "real_serial", withExtension: "json", subdirectory: "Fixtures"))
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(contentsOf: url)).item
        XCTAssertEqual(item.title, "Голубые огни")
        XCTAssertTrue(item.isSerial)
        let ep = try XCTUnwrap(item.seasons?.first?.episodes.first)
        XCTAssertEqual(ep.audios.map(\.displayName), ["Многоголосый · NewStudio · Русский · 2.0 AAC", "Оригинал · Английский · 2.0 AAC"])
        XCTAssertEqual(ep.subtitles.count, 2)
        XCTAssertEqual(ep.watched, -1)

        let jobs = DownloadRequest.makeJobs(
            item: item, entries: [.init(season: 1, video: ep)], preferredHeight: 0,
            audio: ep.audios, subtitles: ep.subtitles, settings: EncodePreset.default.settings,
            root: URL(fileURLWithPath: "/tmp/kp")
        )
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.sourceKind, .hls)
        XCTAssertEqual(job.sourceHeight, 720)
        XCTAssertEqual(job.audio.map(\.apiIndex), [1, 2])
        XCTAssertEqual(job.subtitles.map(\.language), ["rus", "eng"])

        let api = KpubAPI(config: APIConfig(apiBase: URL(string: "https://mirror.example")!, oauthBase: APIConfig.officialAPI), tokens: nil)
        let manifest = await api.manifestURL(try XCTUnwrap(job.sourceURL))
        XCTAssertEqual(manifest.absoluteString, "https://mirror.example/manifest/hls4/TOKEN/934141.m3u8?loc=nl")
        let cdn = URL(string: "https://cdn.ams-static-02.cdntogo.net/hls/TOKEN/x.mp4/index-v1.m3u8")!
        let unchanged = await api.manifestURL(cdn)
        XCTAssertEqual(unchanged, cdn)
    }

    func testRealMasterStructure() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-INDEPENDENT-SEGMENTS

        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="RUS #01",LANGUAGE="rus",URI="https://cdn.ams-static-15.cdntogo.net/hls/TOKEN/subtitles/8/e0/1194346.srt/index.m3u8?loc=nl"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio1080",NAME="01. Многоголосый. NewStudio (RUS)",LANGUAGE="rus",DEFAULT=YES,URI="https://cdn/a/1080-1.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio1080",NAME="02. Оригинал (ENG)",LANGUAGE="eng",DEFAULT=NO,URI="https://cdn/a/1080-2.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio720",NAME="01. Многоголосый. NewStudio (RUS)",LANGUAGE="rus",DEFAULT=YES,URI="https://cdn/a/720-1.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio720",NAME="02. Оригинал (ENG)",LANGUAGE="eng",DEFAULT=NO,URI="https://cdn/a/720-2.m3u8"
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=7731303,VIDEO-RANGE=SDR,RESOLUTION=1920x864,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=50,HDCP-LEVEL=NONE,AUDIO="audio1080",SUBTITLES="sub"
        https://cdn/v/1080/index-v1.m3u8
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1934761,VIDEO-RANGE=SDR,RESOLUTION=1280x576,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=50,HDCP-LEVEL=NONE,AUDIO="audio720",SUBTITLES="sub"
        https://cdn/v/720/index-v1.m3u8
        """
        let master = HLSMaster.parse(text, baseURL: URL(string: "https://mirror.example/manifest/hls4/TOKEN/1.m3u8")!)
        let v = master.pickVariant(preferredHeight: 720)
        XCTAssertEqual(v?.url.absoluteString, "https://cdn/v/720/index-v1.m3u8")
        let picked = master.pickAudio(for: v!, apiIndices: [2, 1], positions: [1, 0], preferAC3: false)
        XCTAssertEqual(picked.map(\.rendition.url?.absoluteString), ["https://cdn/a/720-2.m3u8", "https://cdn/a/720-1.m3u8"])
    }
}

final class ExternalSubtitlesTests: XCTestCase {
    let sample = """
    1
    00:00:02,000 --> 00:00:04,079
    WIND WHISTLES

    2
    00:56:20,000 --> 00:56:25,500
    Last line.

    3
    00:56:28,305 --> 00:57:28,652
    Do you want subtitles for any video?
    -=[ ai.OpenSubtitles.com ]=-
    """

    func testRemoveAdsAndLastCue() {
        let cleaned = SRT.removeAds(sample)
        XCTAssertFalse(cleaned.lowercased().contains("opensubtitles"))
        XCTAssertEqual(SRT.blocks(cleaned).count, 2)
        XCTAssertEqual(SRT.lastCueEnd(cleaned)!, 3385.5, accuracy: 0.001)
        XCTAssertTrue(OpenSubtitles.fits(lastCueEnd: 3385.5, duration: 3434))
        XCTAssertFalse(OpenSubtitles.fits(lastCueEnd: 3600, duration: 3434), "сабы длиннее серии — другая версия")
    }

    func testGzipRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kp-gz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub.srt")
        try sample.write(to: file, atomically: true, encoding: .utf8)
        let gz = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-k", "-f", file.path])
        XCTAssertEqual(gz.status, 0)
        let packed = try Data(contentsOf: dir.appendingPathComponent("sub.srt.gz"))
        XCTAssertTrue(Gzip.isGzip(packed))
        XCTAssertEqual(OpenSubtitles.decode(packed, encoding: "UTF-8"), sample)
    }

    func testRanking() throws {
        let json = """
        [{"SubFormat":"srt","SubSumCD":"1","SubDownloadsCnt":"20000","SubHearingImpaired":"1","SubFromTrusted":"1","MovieReleaseName":"Show.S01E01.WEB","SubDownloadLink":"https://x/1"},
         {"SubFormat":"srt","SubSumCD":"1","SubDownloadsCnt":"500","SubHearingImpaired":"0","MovieReleaseName":"Show.S01E01.HDTV","MovieTimeMS":"3434000","SubDownloadLink":"https://x/2"},
         {"SubFormat":"srt","SubSumCD":"2","SubDownloadsCnt":"90000","SubDownloadLink":"https://x/3"},
         {"SubFormat":"srt","SubSumCD":"1","SubDownloadsCnt":"90000","SubAutoTranslation":"1","SubDownloadLink":"https://x/4"}]
        """
        let list = try JSONDecoder().decode([OpenSubtitles.Candidate].self, from: Data(json.utf8))
        let ranked = OpenSubtitles.rank(list, duration: 3434, isEpisode: true)
        XCTAssertEqual(ranked.compactMap(\.SubDownloadLink?.absoluteString), ["https://x/2", "https://x/1"], "точная длительность важнее популярности; 2CD и автоперевод отброшены")
    }

    func testExternalOnlyWhenMissingOnKpub() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "real_serial", withExtension: "json", subdirectory: "Fixtures"))
        let item = try JSONDecoder().decode(ItemResponse.self, from: Data(contentsOf: url)).item
        XCTAssertEqual(item.imdb, 14466018)
        let ep1 = item.seasons![0].episodes[0]  // есть rus+eng
        let noSubs = Video(id: 2, number: 2, title: nil, duration: 3451, files: ep1.files, audios: ep1.audios, subtitles: [])
        let jobs = DownloadRequest.makeJobs(
            item: item, entries: [.init(season: 1, video: ep1), .init(season: 1, video: noSubs)], preferredHeight: 0,
            audio: ep1.audios, subtitles: [], settings: EncodePreset.default.settings,
            root: URL(fileURLWithPath: "/tmp/kp"), externalSubtitleLanguages: ["eng"]
        )
        XCTAssertEqual(jobs.map(\.externalSubtitleLanguages), [[], ["eng"]])
        XCTAssertEqual(jobs[1].imdbID, 14466018)
    }

    /// Живой запрос к OpenSubtitles: KP_LIVE=1 swift test --filter testLiveOpenSubtitles
    func testLiveOpenSubtitles() async throws {
        guard ProcessInfo.processInfo.environment["KP_LIVE"] == "1" else { throw XCTSkip("KP_LIVE не задан") }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("kp-live-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: dest) }
        let env = ProcessInfo.processInfo.environment
        let found = try await OpenSubtitles.fetch(
            imdbID: Int(env["KP_IMDB"] ?? "") ?? 14466018, season: Int(env["KP_SEASON"] ?? "") ?? 1,
            episode: Int(env["KP_EPISODE"] ?? "") ?? 1, language: "eng",
            duration: Double(env["KP_DURATION"] ?? "") ?? 3434, to: dest
        )
        XCTAssertTrue(found)
        let text = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertGreaterThan(SRT.blocks(text).count, 300)
        XCTAssertFalse(text.lowercased().contains("opensubtitles"))
        print("LIVE: cues=\(SRT.blocks(text).count) last=\(SRT.lastCueEnd(text) ?? 0)")
    }
}

final class SubtitleStyleTests: XCTestCase {
    func testStyleLine() {
        let style = SubtitleStyle(opacity: 0.5, scale: 0.9)
        XCTAssertTrue(style.assStyleLine.contains(",14,&H80FFFFFF,"), style.assStyleLine)
        XCTAssertTrue(SubtitleStyle().isDefault)
        let ass = "[V4+ Styles]\nFormat: Name\nStyle: Default,Arial,16,&Hffffff\nStyle: Alt,Arial\n\n[Events]\nDialogue: x"
        let applied = style.apply(toASS: ass)
        XCTAssertEqual(applied.components(separatedBy: "Style: ").count - 1, 1)
        XCTAssertTrue(applied.contains("Dialogue: x"))
    }

    func testRestyleExistingMKV() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("ffmpeg не установлен") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kp-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = dir.appendingPathComponent("s.srt")
        try "1\n00:00:00,500 --> 00:00:01,500\n<i>Hello</i>\n".write(to: srt, atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("ep.mkv")
        let make = try await ProcessRunner.run(tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:duration=2",
            "-f", "lavfi", "-i", "sine=duration=2", "-i", srt.path, "-map", "0", "-map", "1", "-map", "2",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-c:s", "srt",
            "-metadata:s:a:0", "language=eng", "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=English", file.path,
        ])
        XCTAssertEqual(make.status, 0, make.stderr)

        let changed = try await SubtitleStyler.restyle(tools, file: file, style: SubtitleStyle(opacity: 0.5, scale: 1))
        XCTAssertTrue(changed)
        let probe = try await FFprobe.probe(tools, input: file.path)
        XCTAssertEqual(probe.video?.codecName, "h264")
        XCTAssertEqual(probe.audio.first?.language, "eng")
        XCTAssertEqual(probe.subtitles.first?.codecName, "ass")
        XCTAssertEqual(probe.subtitles.first?.language, "eng")
        XCTAssertEqual(probe.subtitles.first?.title, "English")
        let dump = try await ProcessRunner.run(tools.ffmpeg, arguments: ["-v", "error", "-i", file.path, "-map", "0:s:0", "-f", "ass", "-"])
        XCTAssertTrue(dump.stdout.contains("&H80FFFFFF"), dump.stdout)
        XCTAssertTrue(dump.stdout.contains("{\\i1}Hello"))
    }
}

final class AddSubtitleTests: XCTestCase {
    func testAddSubtitleToMKVAndMP4() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("ffmpeg не установлен") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kp-addsub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = dir.appendingPathComponent("s.srt")
        try "1\n00:00:00,500 --> 00:00:01,500\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        for (ext, codec, style) in [("mkv", "ass", SubtitleStyle(opacity: 0.6)), ("mkv", "subrip", SubtitleStyle()), ("mp4", "mov_text", SubtitleStyle(opacity: 0.6))] {
            let file = dir.appendingPathComponent("ep-\(codec).\(ext)")
            let make = try await ProcessRunner.run(tools.ffmpeg, arguments: [
                "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:duration=2",
                "-f", "lavfi", "-i", "sine=duration=2", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", file.path,
            ])
            XCTAssertEqual(make.status, 0, make.stderr)
            try await SubtitleStyler.addSubtitle(tools, file: file, subtitle: srt, language: "eng", title: "Английский (OpenSubtitles)", style: style)
            let probe = try await FFprobe.probe(tools, input: file.path)
            XCTAssertEqual(probe.subtitles.map(\.codecName), [codec], ext)
            XCTAssertEqual(probe.subtitles.first?.language, "eng")
            XCTAssertEqual(probe.video?.codecName, "h264")
            XCTAssertEqual(probe.audio.count, 1)
        }
    }
}

final class MirrorAddressTests: XCTestCase {
    func testNormalizeMirror() {
        XCTAssertNil(MirrorAddress.normalize(""))
        XCTAssertNil(MirrorAddress.normalize("http://mirror.example"))
        XCTAssertNil(MirrorAddress.normalize("https://user:password@mirror.example"))
        XCTAssertNil(MirrorAddress.normalize("https://mirror.example/path"))
        XCTAssertNil(MirrorAddress.normalize("https://mirror.example?token=x"))
        XCTAssertEqual(MirrorAddress.normalize(" mirror.example/ ")?.absoluteString, "https://mirror.example")
        XCTAssertEqual(MirrorAddress.normalize("https://mirror.example/")?.absoluteString, "https://mirror.example")
    }
}

final class PosterCacheTests: XCTestCase {
    func testPersistsArtworkAcrossCacheInstancesAndRejectsHTML() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://artwork.example/poster.jpg")!
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK1cAAAAASUVORK5CYII=")!
        let cache = PosterCache(directory: dir)
        let stored = try await cache.store(png, for: url)
        XCTAssertTrue(stored)
        let reopened = PosterCache(directory: dir)
        let loaded = await reopened.cachedData(for: url)
        XCTAssertEqual(loaded, png)
        let rejected = try await reopened.store(Data("<html>Error</html>".utf8), for: url)
        XCTAssertFalse(rejected)
        let retained = await reopened.cachedData(for: url)
        XCTAssertEqual(retained, png)
    }
}
