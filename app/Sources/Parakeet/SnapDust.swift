import AppKit
import Metal
import QuartzCore

/// The picture crumbling at its edges: grains of the screen itself break off
/// its rim, each the colour of the pixel it came from, and drift out into the
/// dark. Simulated on the CPU, drawn as points by Metal.
final class DustLayer: CAMetalLayer {
    private struct Grain {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var color: SIMD4<Float>
        var size: Float
        var age: Float
        var life: Float
    }

    /// What the shader reads: position and size in pixels, premultiplied later.
    private struct Point {
        var position: SIMD2<Float>
        var size: Float
        var alpha: Float
        var color: SIMD4<Float>
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Point { float2 position; float size; float alpha; float4 color; };
    struct Out { float4 position [[position]]; float size [[point_size]]; float4 color; };
    vertex Out dustVertex(const device Point *points [[buffer(0)]], constant float2 &viewport [[buffer(1)]], uint id [[vertex_id]]) {
        Point p = points[id];
        Out out;
        float2 ndc = p.position / viewport * 2.0 - 1.0;
        out.position = float4(ndc.x, -ndc.y, 0, 1);
        out.size = p.size;
        out.color = float4(p.color.rgb * p.alpha, p.alpha);
        return out;
    }
    fragment float4 dustFragment(Out in [[stage_in]], float2 at [[point_coord]]) {
        // A chip of the screen: square, its edges just softened.
        float2 d = abs(at - 0.5) * 2.0;
        return in.color * smoothstep(1.0, 0.75, max(d.x, d.y));
    }
    """

    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let buffer: MTLBuffer
    private let capacity = 30000
    private var grains: [Grain] = []
    /// The screen's pixels, to colour each grain by where it broke off.
    private let pixels: Data
    private let imageSize: (width: Int, height: Int)
    private let imageScale: CGFloat
    /// The picture on the sheet (points), and how much it's shrunk from the screen.
    private let frameRect: CGRect
    private let shrink: CGFloat
    private let band: CGFloat
    private var spawnRate: Float = 0
    private var carry: Float = 0
    private var clock: Float = 0
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    init?(image: CGImage, imageScale: CGFloat, picture: CGRect, shrink: CGFloat, band: CGFloat, view: NSView) {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let buffer = device.makeBuffer(length: MemoryLayout<Point>.stride * 30000, options: .storageModeShared) else { return nil }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "dustVertex")
        description.fragmentFunction = library.makeFunction(name: "dustFragment")
        let attachment = description.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: description) else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.makeImage()?.dataProvider?.data as Data? else { return nil }
        self.commands = commands
        self.pipeline = pipeline
        self.buffer = buffer
        pixels = data
        imageSize = (width, height)
        self.imageScale = imageScale
        frameRect = picture
        self.shrink = shrink
        self.band = band
        super.init()
        self.device = device
        pixelFormat = .bgra8Unorm
        isOpaque = false
        framebufferOnly = true
        grains.reserveCapacity(capacity)
        link = view.displayLink(target: self, selector: #selector(step))
        link?.add(to: .main, forMode: .common)
    }

    override init(layer: Any) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }

    /// Starts the edge crumbling, with a first burst as the picture lands.
    func start() {
        for _ in 0..<9000 { spawn(burst: true) }
        spawnRate = 4200
    }

    /// Stops the crumbling; the grains already loose fade out faster.
    func stop() {
        spawnRate = 0
        for i in grains.indices { grains[i].life = min(grains[i].life, grains[i].age + 0.35) }
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = Float(last == 0 ? 1.0 / 60 : min(now - last, 1.0 / 20))
        last = now
        clock += dt
        carry += spawnRate * dt
        while carry >= 1 { spawn(burst: false); carry -= 1 }
        // Drift: a slow swirl, a little lift, and air that slows them.
        var alive = 0
        for i in grains.indices {
            var g = grains[i]
            g.age += dt
            guard g.age < g.life else { continue }
            let p = g.position
            let q = p / Float(contentsScale)
            let swirl = SIMD2<Float>(sin(q.y * 0.018 + clock * 1.3) + 0.5 * sin(q.y * 0.041 - clock * 0.7),
                                     cos(q.x * 0.018 + clock * 1.1) + 0.5 * cos(q.x * 0.037 + clock * 0.9))
            g.velocity += swirl * 70 * Float(contentsScale) * dt
            g.velocity.y -= 12 * Float(contentsScale) * dt
            g.velocity *= 0.965
            g.position += g.velocity * dt
            grains[alive] = g
            alive += 1
        }
        grains.removeLast(grains.count - alive)
        draw()
    }

    private func spawn(burst: Bool) {
        guard grains.count < capacity else { return }
        let rect = frameRect
        // A point on the rim, more often right at the edge than deeper in.
        let w = rect.width, h = rect.height
        let along = CGFloat.random(in: 0..<2 * (w + h))
        let depth = band * pow(CGFloat.random(in: 0...1), 2)
        let point: CGPoint, outward: CGVector
        switch along {
        case ..<w: (point, outward) = (CGPoint(x: rect.minX + along, y: rect.minY + depth), CGVector(dx: 0, dy: -1))
        case ..<(w + h): (point, outward) = (CGPoint(x: rect.maxX - depth, y: rect.minY + along - w), CGVector(dx: 1, dy: 0))
        case ..<(2 * w + h): (point, outward) = (CGPoint(x: rect.maxX - (along - w - h), y: rect.maxY - depth), CGVector(dx: 0, dy: 1))
        default: (point, outward) = (CGPoint(x: rect.minX + depth, y: rect.maxY - (along - 2 * w - h)), CGVector(dx: -1, dy: 0))
        }
        // Where that point shows on the screen capture, for its colour.
        let source = CGPoint(x: (point.x - rect.midX) / shrink + rect.midX, y: (point.y - rect.midY) / shrink + rect.midY)
        let x = min(max(Int(source.x * imageScale), 0), imageSize.width - 1)
        let y = min(max(Int(source.y * imageScale), 0), imageSize.height - 1)
        let i = (y * imageSize.width + x) * 4
        let ember = Float.random(in: 0...1) < 0.08
        // Lifted a little, so even dark pixels catch the light against the dark; embers more.
        let lift: Float = ember ? 0.45 : 0.18
        let raw = SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
        let lit = raw * (1 - lift) + SIMD3(repeating: lift)
        let color = SIMD4<Float>(lit.x, lit.y, lit.z, 1)
        let speed = Float.random(in: burst ? 30...130 : 6...42)
        let out = SIMD2<Float>(Float(outward.dx), Float(outward.dy))
        let side = SIMD2<Float>(-out.y, out.x) * Float.random(in: -30...30)
        let scale = Float(contentsScale)
        grains.append(Grain(position: SIMD2(Float(point.x), Float(point.y)) * scale,
                            velocity: (out * speed + side) * scale,
                            color: color,
                            size: (ember ? Float.random(in: 4...7) : Float.random(in: 2...5)) * scale,
                            age: 0,
                            life: Float.random(in: burst ? 1.2...3.2 : 1.8...4.2)))
    }

    private func draw() {
        guard let drawable = nextDrawable(), let commandBuffer = commands.makeCommandBuffer() else { return }
        let points = buffer.contents().bindMemory(to: Point.self, capacity: capacity)
        for (i, g) in grains.enumerated() {
            let t = g.age / g.life
            let alpha = min(t * 10, 1) * (1 - t)  // pops in, then fades
            points[i] = Point(position: g.position, size: g.size * (1 - 0.6 * t), alpha: alpha * g.color.w, color: g.color)  // crumbling smaller as they go
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !grains.isEmpty {
            var viewport = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: grains.count)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The picture's own outline, crumbling: solid inside, and over the last
    /// `band` points before the edge, speckled with holes that grow toward it.
    static func erodedMask(size: CGSize, band: CGFloat, corner: CGFloat) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        let b = Float(band), r = Float(corner)
        var alpha = [UInt8](repeating: 0, count: width * height)
        func hash(_ x: Int, _ y: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263)
            h = (h ^ (h >> 13)) &* 1274126177
            return Float(h & 0xFFFF) / 65535
        }
        func smooth(_ x: Int, _ y: Int, _ cell: Int) -> Float {
            let gx = x / cell, gy = y / cell
            let fx = Float(x % cell) / Float(cell), fy = Float(y % cell) / Float(cell)
            let a = hash(gx, gy), b = hash(gx + 1, gy), c = hash(gx, gy + 1), d = hash(gx + 1, gy + 1)
            let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
            return (a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy
        }
        for y in 0..<height {
            for x in 0..<width {
                // Distance in from the rounded outline.
                let fx = Float(x), fy = Float(y), right = Float(width - 1), bottom = Float(height - 1)
                let dx: Float = Swift.max(r - fx, 0, fx - right + r)
                let dy: Float = Swift.max(r - fy, 0, fy - bottom + r)
                let straight: Float = Swift.min(fx, fy, right - fx, bottom - fy)
                let edge: Float = dx > 0 && dy > 0 ? r - (dx * dx + dy * dy).squareRoot() : straight
                guard edge > 0 else { continue }
                if edge >= b { alpha[y * width + x] = 255; continue }
                let noise = 0.5 * smooth(x, y, 26) + 0.3 * smooth(x, y, 7) + 0.2 * hash(x / 3, y / 3)
                alpha[y * width + x] = noise < edge / b ? 255 : 0
            }
        }
        // White, with the crumble in the alpha: a layer mask reads only that.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) where alpha[i] > 0 {
            rgba[i * 4] = 255; rgba[i * 4 + 1] = 255; rgba[i * 4 + 2] = 255; rgba[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
