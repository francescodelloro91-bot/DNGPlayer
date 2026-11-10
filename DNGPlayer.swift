// DNGPlayer — viewer/player CinemaDNG (Blackmagic Pocket Cinema Camera).
// Build: ./build.sh   Check: DNGPlayer.app/Contents/MacOS/DNGPlayer --check <cartella>
import SwiftUI
import MetalKit
import CoreImage
import AVFoundation

struct Clip: Hashable {
    let dir: URL
    let frames: [URL]
    let wav: URL?
    let fps: Double
    var name: String { dir.lastPathComponent }
}

/// FrameRate (tag 51044, SRATIONAL) da IFD0 del DNG. CGImageSource non lo espone.
func dngFrameRate(_ url: URL) -> Double? {
    guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 8 else { return nil }
    let le = d[0] == 0x49
    func u16(_ o: Int) -> Int? {
        guard o >= 0, o + 2 <= d.count else { return nil }
        let a = Int(d[o]), b = Int(d[o + 1])
        return le ? a | b << 8 : a << 8 | b
    }
    func u32(_ o: Int) -> Int? {
        guard let a = u16(o), let b = u16(o + 2) else { return nil }
        return le ? a | b << 16 : a << 16 | b
    }
    guard let ifd = u32(4), let n = u16(ifd) else { return nil }
    for i in 0..<n {
        let e = ifd + 2 + i * 12
        guard u16(e) == 51044, let off = u32(e + 8), let num = u32(off), let den = u32(off + 4), den != 0 else { continue }
        return Double(num) / Double(den)
    }
    return nil
}

// ponytail: cerca solo nella cartella e nelle sottocartelle dirette; ricorsione se serve.
func scanClips(_ root: URL) -> [Clip] {
    let fm = FileManager.default
    let subs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
        .filter { $0.hasDirectoryPath && $0.pathExtension != "app" }
    return ([root] + subs).compactMap { dir -> Clip? in
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let frames = files.filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = frames.first else { return nil }
        return Clip(dir: dir, frames: frames,
                    wav: files.first { $0.pathExtension.lowercased() == "wav" },
                    fps: dngFrameRate(first) ?? 24)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

// ponytail: curva log "Film" approssimata, non la BMD Film ufficiale (non pubblicata per la Pocket OG).
// Calibrata su BaselineExposure 2.1: nero 4%, grigio 18% al 38%, clip sensore al 100%. LUT 3D per fedeltà.
let filmCurve: Data = {
    let n = 1024
    var v = [Float]()
    for i in 0..<n {
        let y = min(1, 0.2073 * log(Float(i) / Float(n - 1) * 4.29 + 0.042) + 0.696)
        v += [y, y, y]
    }
    return v.withUnsafeBufferPointer { Data(buffer: $0) }
}()

/// Sviluppo RAW. Video: resa Rec.709 standard di Core Image. Film: lineare del sensore + curva log, gamut largo.
func develop(_ url: URL, exposure: Float, scale: Float, film: Bool) -> CIImage? {
    guard let raw = CIRAWFilter(imageURL: url) else { return nil }
    raw.exposure = exposure
    raw.scaleFactor = scale
    guard film else { return raw.outputImage }
    raw.baselineExposure = 0        // clip del sensore = 1.0, niente alte luci tagliate
    raw.boostAmount = 0             // nessuna curva di contrasto: risposta lineare
    raw.isGamutMappingEnabled = false
    return raw.outputImage?
        .matchedFromWorkingSpace(to: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!)?
        .applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": filmCurve,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.linearSRGB)!,
        ])
        .matchedToWorkingSpace(from: CGColorSpace(name: CGColorSpace.sRGB)!)   // valori log mostrati così come sono
}

final class Player: NSObject, ObservableObject, MTKViewDelegate {
    @Published var clips: [Clip] = []
    @Published var clip: Clip? { didSet { load() } }
    @Published var frame = 0
    @Published var playing = false
    @Published var exposure: Float = 0 { didSet { invalidate() } }
    @Published var halfRes = false { didSet { invalidate() } }
    @Published var film = UserDefaults.standard.bool(forKey: "film") {
        didSet { UserDefaults.standard.set(film, forKey: "film"); invalidate() }
    }

    let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private lazy var ctx = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    private var audio: AVAudioPlayer?
    private var base = 0.0      // CACurrentMediaTime del frame 0 (clock senza audio)
    private var shown = -1
    private var dirty = true
    // Cache dei frame decodificati (texture sRGB), protetta da lock; gen invalida i job vecchi.
    private let lock = NSLock()
    private var cache: [Int: MTLTexture] = [:]
    private var pending: Set<Int> = []
    private var window = 0..<0
    private var gen = 0
    // Check: DNGPLAYER_STATS=1 riproduce la prima clip, stampa i frame mostrati ed esce.
    private let stats = ProcessInfo.processInfo.environment["DNGPLAYER_STATS"] != nil
    private var drawn = 0
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let decodeQ: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        return q
    }()

    override init() {
        super.init()
        _ = ctx   // lazy non è thread-safe: inizializza prima dei job di decodifica
        if stats { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.play() } }
        if let last = UserDefaults.standard.string(forKey: "lastFolder") { open(URL(fileURLWithPath: last)) }
        if clips.isEmpty { open(Bundle.main.bundleURL.deletingLastPathComponent()) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
            switch e.keyCode {
            case 49: self.toggle()
            case 123: self.pause(); self.seek(self.frame - 1)
            case 124: self.pause(); self.seek(self.frame + 1)
            default: return e
            }
            return nil
        }
    }

    func open(_ root: URL) {
        let found = scanClips(root)
        guard !found.isEmpty else { return }
        UserDefaults.standard.set(root.path, forKey: "lastFolder")
        clips = found
        clip = found[0]
    }

    private func load() {
        audio?.stop()
        audio = clip?.wav.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        audio?.prepareToPlay()
        playing = false
        frame = 0
        invalidate()
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        guard let clip else { return }
        if frame >= clip.frames.count - 1 { frame = 0 }
        seek(frame)
        audio?.play()
        playing = true
    }

    func pause() {
        audio?.pause()
        playing = false
        if stats, let clip { print("mostrati \(drawn)/\(clip.frames.count) frame"); exit(0) }
    }

    func seek(_ i: Int) {
        guard let clip else { return }
        frame = max(0, min(i, clip.frames.count - 1))
        let t = Double(frame) / clip.fps
        base = CACurrentMediaTime() - t
        audio?.currentTime = t
    }

    private func invalidate() {
        decodeQ.cancelAllOperations()
        lock.lock(); gen += 1; cache = [:]; pending = []; lock.unlock()
        dirty = true
    }

    /// Decodifica in parallelo i frame successivi: un DNG costa ~60 ms, da solo non regge 25 fps.
    private func prefetch(_ clip: Clip) {
        let hi = min(frame + (playing ? 16 : 2), clip.frames.count)
        lock.lock()
        window = (frame - 1)..<(hi + 8)
        cache = cache.filter { window.contains($0.key) }
        let want = (frame..<hi).filter { cache[$0] == nil && !pending.contains($0) }
        pending.formUnion(want)
        let g = gen
        lock.unlock()
        let ev = exposure, scale: Float = halfRes ? 0.5 : 1, fm = film
        for i in want {
            decodeQ.addOperation { [self] in
                lock.lock(); let live = g == gen && window.contains(i); lock.unlock()
                var tex: MTLTexture?
                if live {
                    if let img = develop(clip.frames[i], exposure: ev, scale: scale, film: fm) {
                        let d = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .bgra8Unorm, width: Int(img.extent.width), height: Int(img.extent.height), mipmapped: false)
                        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
                        if let t = device.makeTexture(descriptor: d) {
                            let dest = CIRenderDestination(mtlTexture: t, commandBuffer: nil)
                            let moved = img.transformed(by: .init(translationX: -img.extent.minX, y: -img.extent.minY))
                            if (try? ctx.startTask(toRender: moved, to: dest).waitUntilCompleted()) != nil { tex = t }
                        }
                    }
                }
                lock.lock()
                if g == gen { pending.remove(i); cache[i] = tex }
                lock.unlock()
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { dirty = true }

    func draw(in view: MTKView) {
        guard let clip else { return }
        if playing {
            // Audio è il master clock; finito l'audio (o senza wav) si usa il clock di sistema.
            let t = audio?.isPlaying == true ? audio!.currentTime : CACurrentMediaTime() - base
            let i = Int(t * clip.fps)
            if i >= clip.frames.count { pause() } else if i != frame { frame = i }
        }
        prefetch(clip)
        lock.lock(); let cached = cache[frame]; lock.unlock()
        // Frame non ancora decodificato: resta a schermo il precedente, si riprova al prossimo tick.
        guard frame != shown || dirty, let tex = cached,
              let img = CIImage(mtlTexture: tex, options: [.colorSpace: sRGB]),
              let drawable = view.currentDrawable,
              let buf = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let s = min(size.width / img.extent.width, size.height / img.extent.height)
        let fit = img.transformed(by: .init(scaleX: s, y: s))
        let out = fit
            .transformed(by: .init(translationX: (size.width - fit.extent.width) / 2 - fit.extent.minX,
                                   y: (size.height - fit.extent.height) / 2 - fit.extent.minY))
            .composited(over: CIImage(color: .black))
            .cropped(to: CGRect(origin: .zero, size: size))
        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                       pixelFormat: view.colorPixelFormat, commandBuffer: buf) { drawable.texture }
        _ = try? ctx.startTask(toRender: out, to: dest)
        buf.present(drawable)
        buf.commit()
        shown = frame
        dirty = false
        drawn += 1
    }
}

struct MetalView: NSViewRepresentable {
    let player: Player
    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: player.device)
        v.framebufferOnly = false   // Core Image scrive nella texture del drawable
        v.preferredFramesPerSecond = 60
        (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.delegate = player
        return v
    }
    func updateNSView(_ v: MTKView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var p: Player

    var body: some View {
        NavigationSplitView {
            List(p.clips, id: \.self, selection: $p.clip) { c in
                VStack(alignment: .leading) {
                    Text(c.name).lineLimit(1).truncationMode(.head)
                    Text("\(c.frames.count) frame · \(c.fps, specifier: "%.3g") fps\(c.wav == nil ? " · no audio" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                if p.clip == nil {
                    ContentUnavailableView("Nessuna clip DNG", systemImage: "film", description: Text("Apri una cartella con sequenze CinemaDNG."))
                } else {
                    MetalView(player: p)
                    controls.padding(10)
                }
            }
        }
        .toolbar {
            Button("Apri cartella…", systemImage: "folder") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { p.open(url) }
            }
        }
        .navigationTitle(p.clip?.name ?? "DNGPlayer")
        .frame(minWidth: 900, minHeight: 500)
    }

    var controls: some View {
        let count = p.clip?.frames.count ?? 1, fps = p.clip?.fps ?? 24
        return VStack {
            HStack {
                Button(p.playing ? "Pausa" : "Play", systemImage: p.playing ? "pause.fill" : "play.fill") { p.toggle() }
                    .labelStyle(.iconOnly)
                Slider(value: Binding(get: { Double(p.frame) }, set: { p.seek(Int($0)) }), in: 0...Double(max(count - 1, 1)))
                Text("\(p.frame + 1)/\(count) · \(Double(p.frame) / fps, specifier: "%.2f")s")
                    .monospacedDigit().frame(width: 130, alignment: .trailing)
            }
            HStack {
                Picker("Modalità", selection: $p.film) {
                    Text("Film").tag(true)
                    Text("Video").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                Text("Esposizione \(p.exposure, specifier: "%+.1f") EV").monospacedDigit().frame(width: 150, alignment: .leading)
                Slider(value: $p.exposure, in: -4...4).frame(minWidth: 80, maxWidth: 220)
                Button("Reset") { p.exposure = 0 }.fixedSize()
                Toggle("Metà risoluzione", isOn: $p.halfRes).fixedSize()
                    .help("Decodifica più veloce")
                Spacer(minLength: 0)
            }
            .help("Spazio: play/pausa · ←/→: frame")
        }
    }
}

/// Self-check: scansione, fps dal tag DNG, tempo di decodifica.
func check(_ root: URL) -> Never {
    let clips = scanClips(root)
    precondition(!clips.isEmpty, "nessuna clip in \(root.path)")
    let ctx = CIContext()
    for c in clips {
        precondition(dngFrameRate(c.frames[0]) != nil, "tag FrameRate mancante in \(c.name)")
        let t = CACurrentMediaTime()
        let n = min(10, c.frames.count)
        for (k, f) in c.frames.prefix(n).enumerated() {
            let img = develop(f, exposure: 0, scale: 1, film: k % 2 == 0)!
            precondition(ctx.createCGImage(img, from: img.extent) != nil, "decodifica fallita: \(f.lastPathComponent)")
        }
        print(c.name.suffix(5), c.frames.count, "frame", c.fps, "fps", c.wav != nil ? "wav" : "no-wav",
              String(format: "%.0f ms/frame", (CACurrentMediaTime() - t) / Double(n) * 1000))
    }
    exit(0)
}

@main
struct DNGPlayerApp: App {
    @StateObject private var player = Player()

    init() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--check"), a.count > i + 1 { check(URL(fileURLWithPath: a[i + 1])) }
    }

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(player) }
    }
}
