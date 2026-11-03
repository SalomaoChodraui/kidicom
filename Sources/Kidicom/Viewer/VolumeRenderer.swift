import KidicomKit
import Metal
import MetalKit
import simd

/// A look for the 3D view: which values show, in what color, how opaque.
enum VolumePreset: String, CaseIterable, Identifiable {
    case bone, softTissue, lung, vascular, automatic, current

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .bone: "Bone"
        case .softTissue: "Soft Tissue"
        case .lung: "Lung"
        case .vascular: "Vascular"
        case .automatic: "Automatic"
        case .current: "Current Window"
        }
    }

    /// Window in modality values (HU for CT); nil uses the 2D window.
    var window: VOIWindow? {
        switch self {
        case .bone: VOIWindow(center: 700, width: 1000)
        case .softTissue: VOIWindow(center: 0, width: 600)
        case .lung: VOIWindow(center: -650, width: 500)
        case .vascular: VOIWindow(center: 300, width: 400)
        case .automatic, .current: nil
        }
    }

    /// Color at the low and high end of the window.
    var colors: (SIMD3<Float>, SIMD3<Float>) {
        switch self {
        case .bone: ([0.75, 0.62, 0.45], [1.0, 0.97, 0.9])
        case .softTissue: ([0.7, 0.35, 0.28], [1.0, 0.85, 0.75])
        case .lung: ([0.45, 0.6, 0.8], [0.9, 0.95, 1.0])
        case .vascular: ([0.7, 0.1, 0.1], [1.0, 0.9, 0.85])
        case .automatic, .current: ([0.55, 0.55, 0.55], [1.0, 1.0, 1.0])
        }
    }

    var opacity: Float {
        switch self {
        case .bone: 0.9
        case .softTissue: 0.35
        case .lung: 0.15
        case .vascular: 0.8
        case .automatic, .current: 0.3
        }
    }
}

/// Camera and look of the 3D view.
struct VolumeCamera: Equatable {
    var rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
    var zoom: Float = 1
    /// Pan in fractions of the view height.
    var pan: SIMD2<Float> = .zero
    var window = VOIWindow(center: 700, width: 1000)
    var preset: VolumePreset = .bone
}

private struct Uniforms {
    var viewToTexture: simd_float3x3
    var halfHeight: Float          // mm shown from center to top
    var aspect: Float
    var pan: SIMD2<Float>          // mm
    var depth: Float               // half the volume diagonal, mm
    var step: Float                // mm per sample
    var low: Float                 // window bottom
    var width: Float
    var colorLow: SIMD3<Float>
    var colorHigh: SIMD3<Float>
    var opacity: Float
    var textureStep: SIMD3<Float>  // one voxel in texture units
}

/// Ray-casts a volume into a Metal texture: front to back, gradient shading,
/// orthographic camera that starts looking at the patient's front.
final class VolumeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let texture: MTLTexture
    private let volume: Volume
    var camera: VolumeCamera
    /// Lower resolution while the person drags, full when still.
    var interactive = false

    /// Volume axes (row, column, normal) times physical size, for the camera math.
    private let extent: SIMD3<Float>
    private let axes: simd_float3x3

    init?(volume: Volume, camera: VolumeCamera) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.volume = volume
        self.camera = camera
        extent = SIMD3(Float(Double(volume.width) * volume.spacing.i), Float(Double(volume.height) * volume.spacing.j),
                       Float(Double(volume.depth) * volume.spacing.k))
        let r = volume.rowDirection.map(Float.init), c = volume.columnDirection.map(Float.init), n = volume.normal.map(Float.init)
        axes = simd_float3x3(SIMD3(r[0], r[1], r[2]), SIMD3(c[0], c[1], c[2]), SIMD3(n[0], n[1], n[2]))

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Float
        descriptor.width = volume.width
        descriptor.height = volume.height
        descriptor.depth = volume.depth
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        volume.voxels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth), mipmapLevel: 0, slice: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: volume.width * 2, bytesPerImage: volume.width * volume.height * 2)
        }
        self.texture = texture

        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = library.makeFunction(name: "fullscreen")
            p.fragmentFunction = library.makeFunction(name: "raycast")
            p.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: p)
        } catch {
            print("VolumeRenderer: \(error)")
            return nil
        }
        super.init()
    }

    private func uniforms(width: Int, height: Int) -> Uniforms {
        // View space: x right, y up, z into the screen. Patient space (DICOM):
        // x toward patient left, y posterior, z head. Front view: screen x = patient x,
        // screen up = head, looking from anterior toward posterior.
        let viewFromPatient = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)])
        let rotation = simd_float3x3(camera.rotation)
        let patientFromView = (rotation * viewFromPatient).transpose
        // Texture coordinate = (axesᵀ · patient) / extent + 0.5
        let scale = simd_float3x3(diagonal: 1 / extent)
        let viewToTexture = scale * axes.transpose * patientFromView
        let diagonal = simd_length(extent)
        let spacing = Float(min(volume.spacing.i, min(volume.spacing.j, volume.spacing.k)))
        let low = Float(camera.window.center - camera.window.width / 2)
        let colors = camera.preset.colors
        let halfHeight = diagonal * 0.55 / camera.zoom
        return Uniforms(
            viewToTexture: viewToTexture, halfHeight: halfHeight, aspect: Float(width) / Float(max(height, 1)),
            pan: camera.pan * halfHeight * 2, depth: diagonal / 2, step: spacing * (interactive ? 2 : 0.8),
            low: low, width: Float(max(camera.window.width, 1)), colorLow: colors.0, colorHigh: colors.1,
            opacity: camera.preset.opacity, textureStep: 1 / SIMD3(Float(volume.width), Float(volume.height), Float(volume.depth))
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer() else { return }
        encode(into: buffer, pass: pass, width: Int(view.drawableSize.width), height: Int(view.drawableSize.height))
        buffer.present(drawable)
        buffer.commit()
    }

    private func encode(into buffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, width: Int, height: Int) {
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms(width: width, height: height)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Renders once into an image, for the self-test and snapshots.
    func renderImage(width: Int, height: Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        encode(into: buffer, pass: pass, width: width, height: height)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // BGRA to RGBA.
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        return Renderer.colorImage(bytes, width: width, height: height)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float3x3 viewToTexture;
        float halfHeight;
        float aspect;
        float2 pan;
        float depth;
        float step;
        float low;
        float width;
        float3 colorLow;
        float3 colorHigh;
        float opacity;
        float3 textureStep;
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut fullscreen(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        VOut o;
        o.position = float4(p * 2 - 1, 0, 1);
        o.uv = p * 2 - 1;
        return o;
    }

    fragment float4 raycast(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], texture3d<float> volume [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 origin = float3(in.uv.x * u.halfHeight * u.aspect - u.pan.x, in.uv.y * u.halfHeight - u.pan.y, -u.depth);
        float3 o = u.viewToTexture * origin + 0.5;
        float3 d = u.viewToTexture * float3(0, 0, 1);
        // Enter and leave the unit cube [0, 1]^3.
        float3 inv = 1.0 / d;
        float3 t0 = (0.0 - o) * inv, t1 = (1.0 - o) * inv;
        float tNear = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
        float tFar = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
        if (tNear > tFar || tFar < 0) return float4(0, 0, 0, 1);
        tNear = max(tNear, 0.0);
        float3 color = 0;
        float alpha = 0;
        float3 light = normalize(float3(0.3, 0.5, -1.0));
        float3 lightTex = normalize(u.viewToTexture * light);
        for (float t = tNear; t < tFar && alpha < 0.97; t += u.step) {
            float3 p = o + d * t;
            float v = volume.sample(s, p).r;
            float a = clamp((v - u.low) / u.width, 0.0, 1.0);
            if (a <= 0.001) continue;
            float3 g = float3(
                volume.sample(s, p + float3(u.textureStep.x, 0, 0)).r - volume.sample(s, p - float3(u.textureStep.x, 0, 0)).r,
                volume.sample(s, p + float3(0, u.textureStep.y, 0)).r - volume.sample(s, p - float3(0, u.textureStep.y, 0)).r,
                volume.sample(s, p + float3(0, 0, u.textureStep.z)).r - volume.sample(s, p - float3(0, 0, u.textureStep.z)).r);
            float shade = 0.35 + 0.65 * abs(dot(normalize(g + 1e-6), lightTex));
            float sampleAlpha = 1.0 - pow(1.0 - clamp(a * u.opacity, 0.0, 0.99), u.step);
            float3 c = mix(u.colorLow, u.colorHigh, a) * shade;
            color += (1.0 - alpha) * sampleAlpha * c;
            alpha += (1.0 - alpha) * sampleAlpha;
        }
        return float4(color, 1);
    }
    """
}
