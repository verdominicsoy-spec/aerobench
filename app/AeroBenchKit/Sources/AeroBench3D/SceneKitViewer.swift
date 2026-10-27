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

        clickTarget.action = { [weak self] gesture in
            MainActor.assumeIsolated { self?.handleClick(gesture) }
        }
        let click = NSClickGestureRecognizer(target: clickTarget, action: #selector(ClickTarget.fire(_:)))
        click.buttonMask = 0x1
        click.delaysPrimaryMouseButtonEvents = false
        scnView.addGestureRecognizer(click)
    }

    // MARK: Model

    public func show(_ model: Model3D?) {
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        markerRoot.childNodes.forEach { $0.removeFromParentNode() }
        nodesByID = [:]
        self.model = model
        guard let model else { return }

        let geometries = model.meshes.enumerated().map { Self.geometry(for: $0.element, color: Self.partColor($0.offset)) }
        for root in model.roots {
            modelRoot.addChildNode(build(root, geometries))
        }
        if let b = model.bounds() {
            let lo = SIMD3<Float>(Float(b.min.x), Float(b.min.y), Float(b.min.z))
            let hi = SIMD3<Float>(Float(b.max.x), Float(b.max.y), Float(b.max.z))
            center = (lo + hi) / 2
            radius = max(simd_length(hi - lo) / 2, 1e-4)
        }
        look(from: .iso)
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

/// Gesture recognisers need an Objective-C target; this keeps that out of
/// the main-actor viewer class.
private final class ClickTarget: NSObject {
    var action: ((NSClickGestureRecognizer) -> Void)?

    @objc func fire(_ gesture: NSClickGestureRecognizer) {
        action?(gesture)
    }
}
