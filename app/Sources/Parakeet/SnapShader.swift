import AppKit
import Metal
import MetalKit
import QuartzCore

/// How the picture comes apart, while trying them out:
/// `defaults write plus.lost.parakeet snapEffect curl|cloud`.
enum SnapEffect: String {
    /// Zooming out leaves echoes: the rim keeps shedding streaks of the screen's own
    /// pixels that fly straight out and toward you, in pulsing rings.
    case curl
    /// The screen bursts into a cloud of points in depth and gathers into the picture; its rim stays loose.
    case cloud

    static var current: SnapEffect { SnapEffect(rawValue: UserDefaults.standard.string(forKey: "snapEffect") ?? "") ?? .cloud }
    fileprivate var mode: UInt32 { self == .curl ? 1 : 2 }
}

/// Matches `U` in the shader.
private struct Uniforms {
    var rect: SIMD4<Float>
    var view: SIMD2<Float>
    var mouse: SIMD2<Float>
    var time: Float, dt: Float, intro: Float, spawn: Float
    var band: Float, corner: Float, depth: Float, scale: Float
    var mode: UInt32, count: UInt32, frame: UInt32, cols: UInt32
}

/// Draws the screen picture and its particles in perspective on the GPU.
/// The owner moves `rect` (the picture, in points) and sets `intro` and
/// `spawn` (0...1) from `onFrame`, once per display frame.
final class ShaderLayer: CAMetalLayer {
    var rect = CGRect.zero
    var intro: Float = 0
    var spawn: Float = 0
    /// How fast time runs for the particles: 1 is live, near 0 holds them still.
    var pace: Float = 1
    var mouse = CGPoint.zero
    var onFrame: (CFTimeInterval) -> Void = { _ in }

    private let effect: SnapEffect
    private let queue: MTLCommandQueue
    private let quad: MTLRenderPipelineState
    private let points: MTLRenderPipelineState
    private let step: MTLComputePipelineState
    private let screen: MTLTexture
    private let particles: MTLBuffer
    private let count: Int
    private let cols: Int
    private let rows: Int
    private let band: Float
    private let corner: Float
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var clock: Float = 0
    private var frameNumber: UInt32 = 0

    init?(image: CGImage, size: CGSize, effect: SnapEffect, band: CGFloat, corner: CGFloat, view: NSView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let screen = try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false]) else { return nil }
        func pipeline(_ vertex: String, _ fragment: String, additive: Bool) -> MTLRenderPipelineState? {
            let description = MTLRenderPipelineDescriptor()
            description.vertexFunction = library.makeFunction(name: vertex)
            description.fragmentFunction = library.makeFunction(name: fragment)
            let blend = description.colorAttachments[0]!
            blend.pixelFormat = .bgra8Unorm
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .one
            blend.sourceAlphaBlendFactor = .one
            blend.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: description)
        }
        let cloud = effect == .cloud
        guard let quad = pipeline("quadVertex", "quadFragment", additive: false),
              let points = cloud ? pipeline("cloudVertex", "pointFragment", additive: false)
                                 : pipeline("streakVertex", "streakFragment", additive: true),
              let kernel = library.makeFunction(name: "stepParticles"),
              let step = try? device.makeComputePipelineState(function: kernel) else { return nil }
        // The cloud is one point every 3 points of screen; the others keep a pool of loose particles.
        cols = Int(size.width / 3)
        rows = Int(size.height / (size.width / CGFloat(cols)))
        count = cloud ? cols * rows : 70_000
        guard let particles = device.makeBuffer(length: 64 * (cloud ? 1 : count), options: .storageModePrivate) else { return nil }
        self.effect = effect
        self.queue = queue
        self.quad = quad
        self.points = points
        self.step = step
        self.screen = screen
        self.particles = particles
        self.band = Float(band)
        self.corner = Float(corner)
        super.init()
        self.device = device
        pixelFormat = .bgra8Unorm
        isOpaque = false
        framebufferOnly = true
        // Every particle starts dead: zeroed memory has age = life = 0.
        if let clear = queue.makeCommandBuffer(), let blit = clear.makeBlitCommandEncoder() {
            blit.fill(buffer: particles, range: 0..<particles.length, value: 0)
            blit.endEncoding()
            clear.commit()
        }
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    override init(layer: Any) { fatalError() }
    required init?(coder: NSCoder) { fatalError() }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let real = Float(last == 0 ? 1.0 / 60 : min(now - last, 1.0 / 20))
        last = now
        frameNumber &+= 1
        onFrame(now)
        let dt = real * pace
        clock += dt
        draw(dt: dt)
    }

    private func draw(dt: Float) {
        guard let drawable = nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let view = bounds.size
        var u = Uniforms(rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                         view: SIMD2(Float(view.width), Float(view.height)),
                         mouse: SIMD2(Float(mouse.x), Float(mouse.y)),
                         time: clock, dt: dt, intro: intro, spawn: spawn * pace,  // as many as ever, in slower time
                         band: band, corner: corner, depth: Float(view.height) * 1.87, scale: Float(contentsScale),
                         mode: effect.mode, count: UInt32(count), frame: frameNumber, cols: UInt32(cols))
        let size = MemoryLayout<Uniforms>.stride

        if effect != .cloud, let compute = commands.makeComputeCommandEncoder() {
            compute.setComputePipelineState(step)
            compute.setBuffer(particles, offset: 0, index: 0)
            compute.setBytes(&u, length: size, index: 1)
            compute.setTexture(screen, index: 0)
            let width = step.threadExecutionWidth
            compute.dispatchThreadgroups(MTLSize(width: (count + width - 1) / width, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let render = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        render.setRenderPipelineState(quad)
        render.setVertexBytes(&u, length: size, index: 0)
        render.setFragmentBytes(&u, length: size, index: 0)
        render.setFragmentTexture(screen, index: 0)
        render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        render.setRenderPipelineState(points)
        if effect == .cloud {
            render.setVertexBytes(&u, length: size, index: 0)
            render.setVertexTexture(screen, index: 0)
        } else {
            render.setVertexBuffer(particles, offset: 0, index: 0)
            render.setVertexBytes(&u, length: size, index: 1)
        }
        // The cloud is points; the echoes are streaks, a quad of two triangles each.
        render.drawPrimitives(type: effect == .cloud ? .point : .triangle, vertexStart: 0, vertexCount: effect == .cloud ? count : count * 6)
        render.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U {
    float4 rect; float2 view; float2 mouse;
    float time; float dt; float intro; float spawn;
    float band; float corner; float depth; float scale;
    uint mode; uint count; uint frame; uint cols;
};
// pos: xyz, age; vel: xyz, life; color; misc: uv, seed, -
struct Particle { float4 pos; float4 vel; float4 color; float4 misc; };

// Ashima Arts' simplex noise (MIT).
float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }
float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = mod289(i);
    float4 p = permute(permute(permute(i.z + float4(0.0, i1.z, i2.z, 1.0)) + i.y + float4(0.0, i1.y, i2.y, 1.0))
                       + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

float3 noise3(float3 x) {
    return float3(snoise(x), snoise(float3(x.y - 19.1, x.z + 33.4, x.x + 47.2)), snoise(float3(x.z + 74.2, x.x - 124.5, x.y + 99.4)));
}

// Divergence-free flow: the curl of a noise field, so particles swirl without bunching up.
float3 curl(float3 p) {
    const float e = 0.1;
    float3 dx = float3(e, 0, 0), dy = float3(0, e, 0), dz = float3(0, 0, e);
    float3 x0 = noise3(p - dx), x1 = noise3(p + dx);
    float3 y0 = noise3(p - dy), y1 = noise3(p + dy);
    float3 z0 = noise3(p - dz), z1 = noise3(p + dz);
    return normalize(float3(y1.z - y0.z - z1.y + z0.y, z1.x - z0.x - x1.z + x0.z, x1.y - x0.y - y1.x + y0.x) / (2.0 * e));
}

float rnd(thread uint &s) {
    s = s * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return float((w >> 22u) ^ w) / 4294967295.0;
}

// How far inside the rounded picture a point is, in points; negative outside.
float inside(float2 p, float4 rect, float corner) {
    float2 h = rect.zw * 0.5;
    float2 q = abs(p - (rect.xy + h)) - (h - corner);
    return corner - length(max(q, 0.0)) - min(max(q.x, q.y), 0.0);
}

// A camera looking straight at the sheet: z = 0 lands exactly on its point,
// nearer is bigger. Depth slides a little against the pointer, for parallax.
float4 project(float3 p, constant U &u) {
    p.xy += (u.mouse - u.view * 0.5) / u.view * p.z * 0.3;
    p.z = min(p.z, u.depth * 0.8);
    float k = u.depth / (u.depth - p.z);
    float2 s = (p.xy - u.view * 0.5) * k;
    return float4(s.x / (u.view.x * 0.5), -s.y / (u.view.y * 0.5), 0.0, 1.0);
}

struct QuadOut { float4 position [[position]]; float2 p; };

vertex QuadOut quadVertex(uint id [[vertex_id]], constant U &u [[buffer(0)]]) {
    float2 corner = float2(float(id & 1u), float(id >> 1u));
    QuadOut o;
    o.p = u.rect.xy + corner * u.rect.zw;
    o.position = project(float3(o.p, 0.0), u);
    return o;
}

fragment float4 quadFragment(QuadOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> screen [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = screen.sample(s, (in.p - u.rect.xy) / u.rect.zw).rgb;
    float d = inside(in.p, u.rect, u.corner);
    if (d <= 0.0) discard_fragment();
    float a;
    if (u.mode == 1u) {
        a = smoothstep(0.0, 1.5, d);  // a clean edge for the echoes to leave from
    } else {
        // The rim thins out unevenly into the points.
        float n = snoise(float3(in.p * 0.025, u.time * 0.35)) * 0.5 + 0.5;
        a = mix(1.0, smoothstep(0.0, u.band, d + (n - 0.6) * u.band), u.spawn) * smoothstep(0.7, 1.0, u.intro);
    }
    return float4(c * a, a);
}

// Somewhere along the picture's rim, up to `band` in, and which way is out.
float2 rimPoint(thread uint &s, float4 r, float band, thread float2 &out) {
    float a = rnd(s) * 2.0 * (r.z + r.w);
    float depth = band * pow(rnd(s), 1.6);
    if (a < r.z) { out = float2(0, -1); return float2(r.x + a, r.y + depth); }
    a -= r.z;
    if (a < r.w) { out = float2(1, 0); return float2(r.x + r.z - depth, r.y + a); }
    a -= r.w;
    if (a < r.z) { out = float2(0, 1); return float2(r.x + r.z - a, r.y + r.w - depth); }
    a -= r.z;
    out = float2(-1, 0);
    return float2(r.x + depth, r.y + r.w - a);
}

kernel void stepParticles(device Particle *ps [[buffer(0)]], constant U &u [[buffer(1)]],
                          texture2d<float> screen [[texture(0)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.count) return;
    Particle q = ps[id];
    uint s = id * 1973u + u.frame * 9277u + 1u;
    if (q.pos.w >= q.vel.w) {
        // Released in rings: a pulse every 1.4 s, each an echo of the edge.
        float pulse = pow(0.5 + 0.5 * sin(u.time * 4.49), 8.0);
        if (rnd(s) > u.spawn * 0.006 * (0.25 + 2.5 * pulse)) return;
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        for (int k = 0; k < 4; k++) {
            float2 out;
            float2 p = rimPoint(s, u.rect, 1.5, out);  // right at the edge
            float d = inside(p, u.rect, u.corner);
            if (d < -1.5) continue;
            float2 uv = (p - u.rect.xy) / u.rect.zw;
            q.color = float4(screen.sample(smp, uv).rgb * 0.8 + 0.2, 1.0);
            // Straight out from the middle of the picture, and toward you: the way it zoomed away.
            float2 radial = (p - (u.rect.xy + u.rect.zw * 0.5)) / (u.rect.zw * 0.5);
            float speed = 90.0 + rnd(s) * 160.0;
            q.vel = float4(normalize(radial) * speed, speed * (0.4 + rnd(s) * 0.5), 1.1 + rnd(s) * 1.1);
            q.pos = float4(p, 0.0, 0.0);
            q.misc = float4(uv, rnd(s), 0.0);
            ps[id] = q;
            return;
        }
        return;
    }
    float3 p = q.pos.xyz, v = q.vel.xyz;
    float3 c = curl(p * 0.0035 + float3(0.0, 0.0, u.time * 0.12));
    v *= 1.0 + 1.1 * u.dt;  // speeding up as they go, like the zoom
    v += c * 18.0 * u.dt;   // a little air, not a swirl
    q.pos = float4(p + v * u.dt, q.pos.w + u.dt);
    q.vel.xyz = v;
    ps[id] = q;
}

struct PointOut { float4 position [[position]]; float size [[point_size]]; float4 color; float soft; };

vertex PointOut particleVertex(uint id [[vertex_id]], const device Particle *ps [[buffer(0)]], constant U &u [[buffer(1)]]) {
    Particle q = ps[id];
    PointOut o;
    if (q.pos.w >= q.vel.w) { o.position = float4(2.0, 2.0, 0.0, 1.0); o.size = 0.0; o.color = 0.0; o.soft = 0.0; return o; }
    float t = q.pos.w / q.vel.w;
    float3 p = q.pos.xyz;
    o.position = project(p, u);
    float k = u.depth / (u.depth - min(p.z, u.depth * 0.8));
    // Out of the focal plane, a particle swells, softens and dims: depth of field.
    float blur = clamp(abs(p.z) / 380.0, 0.0, 1.0);
    float base = mix(1.2, 3.0, q.misc.z);
    o.size = base * k * (1.0 + blur * 3.5) * u.scale;
    float a = min(t * 12.0, 1.0) * (1.0 - t) * (1.0 - t) / (1.0 + blur * 4.0);
    o.color = float4(q.color.rgb * a, a);
    o.soft = blur;
    return o;
}

vertex PointOut cloudVertex(uint id [[vertex_id]], constant U &u [[buffer(0)]], texture2d<float> screen [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float gap = u.view.x / float(u.cols);
    float2 home = (float2(float(id % u.cols), float(id / u.cols)) + 0.5) * gap;
    float2 uv = home / u.view;
    float3 c = screen.sample(s, uv, level(0)).rgb;
    float2 target = u.rect.xy + uv * u.rect.zw;
    // On the way in (and out), every point bursts into depth: bright ones
    // toward you, dark ones away, all with a swirl.
    float e = clamp(u.intro, 0.0, 1.0);
    float burst = pow(sin(3.14159 * e), 1.3);
    float lum = dot(c, float3(0.3, 0.59, 0.11));
    float3 scatter = float3(snoise(float3(uv * 4.0, 1.7)) * 140.0, snoise(float3(uv * 4.0 + 11.0, 3.1)) * 140.0,
                            (lum - 0.5) * 520.0 + snoise(float3(uv * 3.0 + 5.0, u.time * 0.2)) * 380.0);
    float2 xy = mix(home, target, smoothstep(0.1, 0.95, e));
    // Settled, only the rim stays loose, drifting in and out of depth.
    float edge = clamp(1.0 - inside(target, u.rect, u.corner) / (u.band * 1.5), 0.0, 1.0);
    edge *= edge;
    float3 drift = float3(snoise(float3(uv * 6.0, u.time * 0.3)) * 45.0, snoise(float3(uv * 6.0 + 7.0, u.time * 0.3)) * 45.0,
                          (snoise(float3(uv * 5.0 + 3.0, u.time * 0.25)) * 0.5 + 0.5) * 340.0) * edge * u.spawn;
    float3 p = float3(xy, 0.0) + scatter * burst + drift;
    PointOut o;
    o.position = project(p, u);
    float k = u.depth / (u.depth - min(p.z, u.depth * 0.8));
    float blur = clamp(abs(p.z) / 420.0, 0.0, 1.0);
    o.size = gap * 0.95 * k * (1.0 + blur * 1.8) * u.scale;
    // Inside, the crisp picture takes over once it has gathered.
    float a = mix(1.0, edge, smoothstep(0.75, 1.0, e)) / (1.0 + blur * 2.0);
    o.color = float4(c * a, a);
    o.soft = blur * 0.7;
    return o;
}

struct StreakOut { float4 position [[position]]; float4 color; float2 local; };

// Each echo is a streak from where it was a moment ago to where it is,
// widening and brightening as it comes closer.
vertex StreakOut streakVertex(uint vid [[vertex_id]], const device Particle *ps [[buffer(0)]], constant U &u [[buffer(1)]]) {
    Particle q = ps[vid / 6u];
    StreakOut o;
    o.color = 0.0;
    o.local = 0.0;
    if (q.pos.w >= q.vel.w) { o.position = float4(2.0, 2.0, 0.0, 1.0); return o; }
    uint corner = vid % 6u;
    float head = (corner == 1u || corner == 4u || corner == 5u) ? 1.0 : 0.0;
    float side = (corner == 2u || corner == 3u || corner == 5u) ? 1.0 : -1.0;
    float3 p = q.pos.xyz;
    float2 h = project(p, u).xy * u.view * 0.5;
    float2 t = project(p - q.vel.xyz * 0.07, u).xy * u.view * 0.5;
    float2 dir = h - t;
    float len = length(dir);
    dir = len > 0.001 ? dir / len : float2(1.0, 0.0);
    float k = u.depth / (u.depth - min(p.z, u.depth * 0.8));
    float width = mix(0.6, 1.6, q.misc.z) * k;
    float2 at = (head > 0.5 ? h + dir * width : t) + float2(-dir.y, dir.x) * side * width;
    o.position = float4(at / (u.view * 0.5), 0.0, 1.0);
    float life = q.pos.w / q.vel.w;
    float a = min(life * 10.0, 1.0) * pow(1.0 - life, 1.5) * 0.9;
    o.color = float4(q.color.rgb * a, a);
    o.local = float2(head, side);
    return o;
}

fragment float4 streakFragment(StreakOut in [[stage_in]]) {
    // Bright at the head, fading to nothing at the tail; soft across.
    return in.color * in.local.x * (1.0 - smoothstep(0.3, 1.0, abs(in.local.y)));
}

fragment float4 pointFragment(PointOut in [[stage_in]], float2 at [[point_coord]]) {
    float r = length(at - 0.5) * 2.0;
    return in.color * smoothstep(1.0, mix(0.55, 0.0, in.soft), r);
}
"""
