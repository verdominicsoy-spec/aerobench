import AeroBenchKit
import AppKit
import SceneKit
import simd

@MainActor
public final class SceneKitViewer: Viewer3D {
    private let scnView: SCNView
    private let scene = SCNScene()
    private let modelRoot = SCNNode()
    private let markerRoot = SCNNode()
    private let overlayRoot = SCNNode()
    private let pointsNode = SCNNode()
    private let sliceNode = SCNNode()
    private let frameNode = SCNNode()
    private var frameBounds: (min: SIMD3<Double>, max: SIMD3<Double>)?
    private let cameraNode = SCNNode()
    private var model: Model3D?
    private var nodesByID: [Int: SCNNode] = [:]
    private var center = SIMD3<Float>(0, 0, 0)
    private var radius: Float = 1
    private var currentView: StandardView = .iso
    private let clickTarget = ClickTarget()

    public var onPick: ((PickResult) -> Void)?
    public var snapToVertices = true

    public var projection: Projection = .perspective {
        didSet {
            cameraNode.camera?.usesOrthographicProjection = projection == .orthographic
            fitAll()
        }
    }

    public var upAxis: UpAxis = .z {
        didSet { look(from: currentView) }
    }

    public var showsStatistics: Bool {
        get { scnView.showsStatistics }
        set { scnView.showsStatistics = newValue }
    }

    public var view: NSView { scnView }

    public init() {
        scnView = SCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), options: nil)
        scnView.scene = scene
        scnView.backgroundColor = .windowBackgroundColor
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = true
        scnView.defaultCameraController.interactionMode = .orbitTurntable
        scnView.defaultCameraController.inertiaEnabled = true

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.fieldOfView = 35
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        // A headlight that follows the camera, plus soft ambient fill.
        let head = SCNNode()
        head.light = SCNLight()
        head.light?.type = .directional
        head.light?.intensity = 900
        cameraNode.addChildNode(head)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        scene.rootNode.addChildNode(modelRoot)
        scene.rootNode.addChildNode(markerRoot)
        scene.rootNode.addChildNode(overlayRoot)
        overlayRoot.addChildNode(pointsNode)
        overlayRoot.addChildNode(sliceNode)
        overlayRoot.addChildNode(frameNode)

        clickTarget.action = { [weak self] gesture in
            MainActor.assumeIsolated { self?.handleClick(gesture) }
        }
        let click = NSClickGestureRecognizer(target: clickTarget, action: #selector(ClickTarget.fire(_:)))
        click.buttonMask = 0x1
        click.delaysPrimaryMouseButtonEvents = false
        scnView.addGestureRecognizer(click)
    }

    // MARK: Model

    public func show(_ model: Model3D?, resetCamera: Bool) {
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        markerRoot.childNodes.forEach { $0.removeFromParentNode() }
        nodesByID = [:]
        self.model = model
        if let model {
            let geometries = model.meshes.enumerated().map { Self.geometry(for: $0.element, color: Self.partColor($0.offset)) }
            for root in model.roots {
                modelRoot.addChildNode(build(root, geometries))
            }
        }
        updateExtent()
        if resetCamera { look(from: .iso) }
    }

    /// Camera framing comes from the explicit frame if set, else the model.
    private func updateExtent() {
        guard let b = frameBounds ?? model?.bounds() else { return }
        let lo = SIMD3<Float>(Float(b.min.x), Float(b.min.y), Float(b.min.z))
        let hi = SIMD3<Float>(Float(b.max.x), Float(b.max.y), Float(b.max.z))
        center = (lo + hi) / 2
        radius = max(simd_length(hi - lo) / 2, 1e-4)
    }

    public func setHidden(_ ids: Set<Int>) {
        for (id, node) in nodesByID {
            node.isHidden = ids.contains(id)
        }
    }

    private func build(_ node: ModelNode, _ geometries: [SCNGeometry?]) -> SCNNode {
        let n = SCNNode()
        n.name = String(node.id)
        n.simdTransform = node.transform
        if let m = node.mesh, m < geometries.count {
            n.geometry = geometries[m]
        }
        nodesByID[node.id] = n
        for c in node.children {
            n.addChildNode(build(c, geometries))
        }
        return n
    }

    static func geometry(for mesh: TriangleMesh, color: NSColor) -> SCNGeometry? {
        guard mesh.triangleCount > 0 else { return nil }
        let stride3 = MemoryLayout<SIMD3<Float>>.stride
        let vertexData = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }
        var sources = [
            SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: mesh.positions.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: stride3),
            SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: mesh.normals.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: stride3),
        ]
        if let colors = mesh.colors, colors.count == mesh.positions.count {
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                             usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride))
        }
        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: mesh.triangleCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = mesh.colors == nil ? color : NSColor.white
        material.specular.contents = NSColor(white: 0.25, alpha: 1)
        material.isDoubleSided = true
        if let alpha = mesh.colors?.first?.w, alpha < 0.999 {
            material.transparency = CGFloat(alpha)
            material.transparencyMode = .dualLayer
        }
        geometry.materials = [material]
        return geometry
    }

    /// Muted, distinct colours per part. A plain v1 palette until styling.
    static func partColor(_ i: Int) -> NSColor {
        let hue = (Double(i) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        return NSColor(calibratedHue: hue, saturation: 0.28, brightness: 0.86, alpha: 1)
    }

    // MARK: Camera

    /// Direction from the model centre to the camera, and the up vector, in
    /// a z-up frame. Front looks along +x, so front is at -x.
    private static func zUpFrame(_ view: StandardView) -> (SIMD3<Float>, SIMD3<Float>) {
        switch view {
        case .front: return (SIMD3(-1, 0, 0), SIMD3(0, 0, 1))
        case .back: return (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .left: return (SIMD3(0, -1, 0), SIMD3(0, 0, 1))
        case .right: return (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .top: return (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        case .bottom: return (SIMD3(0, 0, -1), SIMD3(1, 0, 0))
        case .iso: return (simd_normalize(SIMD3(-1, -1, 0.8)), SIMD3(0, 0, 1))
        }
    }

    private func frame(_ view: StandardView) -> (SIMD3<Float>, SIMD3<Float>) {
        let (d, up) = Self.zUpFrame(view)
        guard upAxis == .y else { return (d, up) }
        // z-up to y-up: (x, y, z) -> (x, z, -y)
        let map = { (v: SIMD3<Float>) in SIMD3<Float>(v.x, v.z, -v.y) }
        return (map(d), map(up))
    }

    public func look(from view: StandardView) {
        currentView = view
        let (dir, up) = frame(view)
        place(direction: dir, up: up)
    }

    public func fitAll() {
        let offset = cameraNode.simdPosition - center
        let dir = simd_length(offset) > 0 ? simd_normalize(offset) : frame(currentView).0
        place(direction: dir, up: cameraNode.simdWorldUp)
    }

    private func place(direction: SIMD3<Float>, up: SIMD3<Float>) {
        guard let camera = cameraNode.camera else { return }
        let size = scnView.bounds.size
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1
        let halfV = Float(camera.fieldOfView) * .pi / 360
        let halfH = atan(tan(halfV) * aspect)
        let half = min(halfV, halfH)
        let distance = radius / sin(half) * 1.05
        cameraNode.simdPosition = center + direction * distance
        cameraNode.simdLook(at: center, up: up, localFront: SIMD3(0, 0, -1))
        camera.orthographicScale = Double(radius * 1.05 * max(1, 1 / aspect))
        scnView.defaultCameraController.target = SCNVector3(center)
        scnView.defaultCameraController.worldUp = SCNVector3(up)
    }

    // MARK: Picking and markers

    private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let onPick, model != nil else { return }
        let p = gesture.location(in: scnView)
        let hits = scnView.hitTest(p, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
            .rootNode: modelRoot,
        ])
        guard let hit = hits.first else { return }
        let w = hit.simdWorldCoordinates
        var point = SIMD3<Double>(Double(w.x), Double(w.y), Double(w.z))
        let id = hit.node.name.flatMap { Int($0) }
        var snapped = false
        if snapToVertices, let id, let meshIndex = model?.node(id: id)?.mesh,
           let mesh = model?.meshes[meshIndex], let tri = mesh.triangle(hit.faceIndex) {
            let world = hit.node.simdWorldTransform
            let corners = [tri.0, tri.1, tri.2].map { v -> SIMD3<Double> in
                let c = world * SIMD4<Float>(v, 1)
                return SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
            }
            point = Measure.nearestCorner(to: point, of: corners)
            snapped = true
        }
        onPick(PickResult(point: point, nodeID: id, snapped: snapped))
    }

    public func setMarkers(_ points: [SIMD3<Double>]) {
        markerRoot.childNodes.forEach { $0.removeFromParentNode() }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.systemRed
        material.readsFromDepthBuffer = false
        let floats = points.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        for p in floats {
            let sphere = SCNSphere(radius: CGFloat(radius * 0.008))
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.simdPosition = p
            node.renderingOrder = 100
            markerRoot.addChildNode(node)
        }
        if floats.count == 2 {
            let source = SCNGeometrySource(vertices: floats.map { SCNVector3($0) })
            let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
            let line = SCNGeometry(sources: [source], elements: [element])
            line.materials = [material]
            let node = SCNNode(geometry: line)
            node.renderingOrder = 100
            markerRoot.addChildNode(node)
        }
    }
}

// MARK: Overlays: frame box, points, slice

extension SceneKitViewer {
    public func setFrame(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>)?) {
        frameBounds = bounds
        frameNode.childNodes.forEach { $0.removeFromParentNode() }
        updateExtent()
        guard let b = bounds else { return }
        let lo = SIMD3<Float>(Float(b.min.x), Float(b.min.y), Float(b.min.z))
        let hi = SIMD3<Float>(Float(b.max.x), Float(b.max.y), Float(b.max.z))
        var corners: [SIMD3<Float>] = []
        for i in 0..<8 {
            corners.append(SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z))
        }
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        let source = SCNGeometrySource(vertices: corners.map { SCNVector3($0) })
        let element = SCNGeometryElement(indices: edges.flatMap { [Int32($0.0), Int32($0.1)] }, primitiveType: .line)
        let box = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.secondaryLabelColor
        box.materials = [material]
        frameNode.addChildNode(SCNNode(geometry: box))

        // Real-unit labels at the ends of the three box edges from the min corner.
        func mm(_ v: Float) -> String { String(format: "%.0f", v * 1000) }
        let size = simd_length(hi - lo)
        let labels: [(String, SIMD3<Float>)] = [
            ("\(mm(lo.x)), \(mm(lo.y)), \(mm(lo.z)) mm", lo),
            ("x \(mm(hi.x)) mm", SIMD3(hi.x, lo.y, lo.z)),
            ("y \(mm(hi.y)) mm", SIMD3(lo.x, hi.y, lo.z)),
            ("z \(mm(hi.z)) mm", SIMD3(lo.x, lo.y, hi.z)),
        ]
        for (text, position) in labels {
            let geometry = SCNText(string: text, extrusionDepth: 0)
            geometry.font = NSFont.systemFont(ofSize: 12)
            geometry.flatness = 0.2
            let textMaterial = SCNMaterial()
            textMaterial.lightingModel = .constant
            textMaterial.diffuse.contents = NSColor.labelColor
            textMaterial.readsFromDepthBuffer = false
            geometry.materials = [textMaterial]
            let node = SCNNode(geometry: geometry)
            let scale = size * 0.025 / 12
            node.simdScale = SIMD3(repeating: scale)
            node.simdPosition = position
            node.renderingOrder = 50
            node.constraints = [SCNBillboardConstraint()]
            frameNode.addChildNode(node)
        }
    }

    public func setPoints(_ positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        pointsNode.geometry = nil
        guard !positions.isEmpty, colors.count == positions.count else { return }
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let sources = [
            SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: positions.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride),
            SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                              componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride),
        ]
        let indices = (0..<UInt32(positions.count)).map { $0 }
        let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .point,
                                         primitiveCount: positions.count, bytesPerIndex: 4)
        element.pointSize = 3
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 6
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        pointsNode.geometry = geometry
    }

    public func setSlice(_ image: CGImage?, x: Double, y: ClosedRange<Double>, z: ClosedRange<Double>) {
        sliceNode.geometry = nil
        guard let image else { return }
        let plane = SCNPlane(width: CGFloat(y.upperBound - y.lowerBound), height: CGFloat(z.upperBound - z.lowerBound))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.magnificationFilter = .nearest
        material.isDoubleSided = true
        material.transparency = 0.9
        plane.materials = [material]
        sliceNode.geometry = plane
        // SCNPlane lies in its local x-y plane: map local x to world y,
        // local y to world z, so its normal points along world x.
        sliceNode.simdTransform = simd_float4x4(columns: (
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(1, 0, 0, 0),
            SIMD4(Float(x), Float((y.lowerBound + y.upperBound) / 2), Float((z.lowerBound + z.upperBound) / 2), 1)
        ))
    }
}

/// Gesture recognisers need an Objective-C target; this keeps that out of
/// the main-actor viewer class.
private final class ClickTarget: NSObject {
    var action: ((NSClickGestureRecognizer) -> Void)?

    @objc func fire(_ gesture: NSClickGestureRecognizer) {
        action?(gesture)
    }
}
