import AeroBenchKit
import AppKit
import SceneKit
import simd

@MainActor
public final class SceneKitViewer: Viewer3D {
    private let scnView: OrbitSCNView
    private var orbit = OrbitCamera()
    /// Orbit centre for the current drag or rotate gesture: the point under
    /// the cursor where it started.
    private var pivot: SIMD3<Double>?
    /// Point the current pinch or scroll zooms toward, fixed for the gesture.
    private var gestureAnchor: SIMD3<Double>?
    private let scene = SCNScene()
    private let modelRoot = SCNNode()
    private let markerRoot = SCNNode()
    private let previewRoot = SCNNode()
    private let editRoot = SCNNode()
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
    private let doubleClickTarget = ClickTarget()
    private let normalCamera = SCNCamera()
    /// Used while peeking: its projectionTransform is the off-axis window.
    private let peekCamera = SCNCamera()
    private var peekMonitor: Any?
    private var peekObservers: [NSObjectProtocol] = []
    private var peekLink: CADisplayLink?
    private let peekLinkTarget = LinkTarget()
    /// A grid room behind the window, shown while peeking: its front edges sit
    /// on the view's edges, which is what makes the depth read (every reference
    /// demo has one).
    private let peekRoom = SceneKitViewer.makePeekRoom()

    /// Hold Shift to peek with head tracking. nil: no peeking (the Flow Field viewer).
    public var peek: HeadPeek? {
        didSet { installPeek() }
    }

    /// A peek is showing (fully or easing).
    public var isPeeking: Bool { (peek?.blend ?? 0) > 0 }

    public var onPick: ((PickResult) -> Void)?
    /// Edit mode: hover and click report the screen point even with nothing
    /// under it, so an edge on a silhouette can still be picked.
    public var onEditHover: ((EditPointer) -> Void)?
    public var onEditClick: ((EditPointer) -> Void)?
    /// The measure tool's pointer: every mouse move, and a click (before onPick).
    public var onHover: ((EditPointer) -> Void)?
    public var onClickPointer: ((EditPointer) -> Void)?
    /// After every camera move, so overlays placed in view points can follow.
    public var onCameraChange: (() -> Void)?
    /// Changes whenever the camera moves, so screen projections can be cached between moves.
    public private(set) var cameraRevision = 0
    public var snapToVertices = true
    /// Screen size of points shown with setPoints, in points.
    public var pointSize: CGFloat = 3

    public var projection: Projection = .perspective {
        didSet {
            orbit.orthographic = projection == .orthographic
            normalCamera.usesOrthographicProjection = orbit.orthographic
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
        scnView = OrbitSCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), options: nil)
        scnView.scene = scene
        scnView.backgroundColor = .windowBackgroundColor
        scnView.antialiasingMode = .multisampling4X
        // Our own camera (OrbitCamera) instead of SceneKit's, which zooms only
        // toward a fixed centre and stops there.
        scnView.allowsCameraControl = false

        let camera = normalCamera
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
        scene.rootNode.addChildNode(previewRoot)
        scene.rootNode.addChildNode(editRoot)
        scene.rootNode.addChildNode(overlayRoot)
        scene.rootNode.addChildNode(peekRoom)
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
        let doubleClick = NSClickGestureRecognizer(target: doubleClickTarget, action: #selector(ClickTarget.fire(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        doubleClickTarget.action = { [weak self] gesture in
            MainActor.assumeIsolated { self?.focus(at: gesture.location(in: gesture.view)) }
        }
        scnView.addGestureRecognizer(doubleClick)
        scnView.onInput = { [weak self] input in self?.handle(input) }
    }

    // MARK: Model

    public func show(_ model: Model3D?, resetCamera: Bool) {
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        markerRoot.childNodes.forEach { $0.removeFromParentNode() }
        previewRoot.childNodes.forEach { $0.removeFromParentNode() }
        editRoot.childNodes.forEach { $0.removeFromParentNode() }
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
        let offset = orbit.position - SIMD3<Double>(center)
        let dir = simd_length(offset) > 0 ? simd_normalize(offset) : SIMD3<Double>(frame(currentView).0)
        place(direction: SIMD3<Float>(dir), up: SIMD3<Float>(orbit.screenUp))
    }

    /// Frames the camera on `points`, keeping the current view direction.
    public func focus(on points: [SIMD3<Double>]) {
        guard let first = points.first else { return }
        let lo = points.reduce(first) { simd_min($0, $1) }, hi = points.reduce(first) { simd_max($0, $1) }
        let mid = (lo + hi) / 2
        let offset = orbit.position - mid
        let dir = simd_length(offset) > 0 ? simd_normalize(offset) : SIMD3<Double>(frame(currentView).0)
        // At least a twentieth of the model across, so a tiny gap is seen in context.
        let r = max(simd_length(hi - lo) / 2, Double(radius) * 0.05)
        pivot = nil
        orbit.frame(center: mid, radius: r, direction: dir, up: orbit.screenUp, aspect: aspect)
        applyCamera()
    }

    private func place(direction: SIMD3<Float>, up: SIMD3<Float>) {
        pivot = nil
        orbit.worldUp = SIMD3<Double>(upAxis == .z ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0))
        orbit.fovY = Double(normalCamera.fieldOfView) * .pi / 180  // not the peek camera's, while peeking
        orbit.frame(center: SIMD3<Double>(center), radius: Double(radius), direction: SIMD3<Double>(direction),
                    up: SIMD3<Double>(up), aspect: aspect)
        applyCamera()
    }

    private var aspect: Double {
        let size = scnView.bounds.size
        return size.height > 0 ? Double(size.width / size.height) : 1
    }

    private func applyCamera() {
        cameraRevision &+= 1
        if let peek, peek.blend > 0, peek.layout != nil {
            applyPeekCamera(peek)
        } else {
            peekRoom.isHidden = true
            cameraNode.camera = normalCamera
            cameraNode.simdPosition = SIMD3<Float>(orbit.position)
            cameraNode.simdLook(at: SIMD3<Float>(orbit.target), up: SIMD3<Float>(orbit.screenUp), localFront: SIMD3(0, 0, -1))
            normalCamera.usesOrthographicProjection = orbit.orthographic
            normalCamera.orthographicScale = orbit.orthoHalfHeight
        }
        onCameraChange?()
    }

    // MARK: Head-tracked peek

    /// The screen as a window: the plane through the orbit target is pinned to
    /// the view's edges, so what you orbit around stays put and moving your
    /// head looks around it. The eye eases from the normal view to the head.
    private func applyPeekCamera(_ peek: HeadPeek) {
        let depth = orbit.distance
        let window = orbit.peekWindow(depth: depth, aspect: aspect)
        let eye = PeekWindow.eye(rest: orbit.restEye(window: window, depth: depth, boundsRadius: Double(radius)),
                                 offsetCM: peek.offsetCM ?? .zero, distanceCM: peek.config.distanceCM, blend: peek.blend)
        let (position, projection) = orbit.peekCamera(window: window, eye: eye, near: 0.05 * eye.z,
                                                      far: eye.z + 4 * Double(radius) + depth)
        peekCamera.projectionTransform = SCNMatrix4(projection)
        cameraNode.camera = peekCamera
        cameraNode.simdPosition = SIMD3<Float>(position)
        // Keep the un-peeked orientation: the off-axis frustum does the looking around.
        cameraNode.simdLook(at: SIMD3<Float>(position + orbit.forward), up: SIMD3<Float>(orbit.screenUp),
                            localFront: SIMD3(0, 0, -1))

        // The room: from the window back to just behind the model.
        let back = max(simd_dot(SIMD3<Double>(center) - orbit.target, orbit.forward) + Double(radius), Double(radius)) * 1.1
        let r = SIMD3<Float>(orbit.right * window.halfWidth), u = SIMD3<Float>(orbit.up * window.halfHeight)
        let z = SIMD3<Float>(-orbit.forward * back)
        peekRoom.simdTransform = simd_float4x4(columns: (SIMD4(r, 0), SIMD4(u, 0), SIMD4(z, 0), SIMD4(SIMD3<Float>(window.center), 1)))
        peekRoom.opacity = CGFloat(peek.blend)
        peekRoom.isHidden = false
    }

    /// A unit grid room: x and y in -1...1, z from 0 (the window) to -1 (the back wall).
    private static func makePeekRoom() -> SCNNode {
        let n = 8
        var v: [SIMD3<Float>] = []
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>) { v += [a, b] }
        for i in 0...n {
            let s = Float(i) / Float(n) * 2 - 1, d = -Float(i) / Float(n)
            line([s, -1, -1], [s, 1, -1]); line([-1, s, -1], [1, s, -1])  // back wall
            line([s, -1, 0], [s, -1, -1]); line([s, 1, 0], [s, 1, -1])  // floor and ceiling, front to back
            line([-1, s, 0], [-1, s, -1]); line([1, s, 0], [1, s, -1])  // side walls, front to back
            line([-1, -1, d], [1, -1, d]); line([-1, 1, d], [1, 1, d])  // floor and ceiling, across
            line([-1, -1, d], [-1, 1, d]); line([1, -1, d], [1, 1, d])  // side walls, up
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: v.map { SCNVector3($0) })],
                                   elements: [SCNGeometryElement(indices: (0..<Int32(v.count)).map { $0 }, primitiveType: .line)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.secondaryLabelColor
        material.writesToDepthBuffer = false  // the model always draws over it
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.isHidden = true
        node.renderingOrder = -1
        return node
    }

    private func installPeek() {
        if let peekMonitor { NSEvent.removeMonitor(peekMonitor) }
        peekObservers.forEach(NotificationCenter.default.removeObserver)
        peekMonitor = nil
        peekObservers = []
        stopPeekLink()
        guard peek != nil else { return }
        peekMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.peekFlagsChanged(event) }
            return event
        }
        // Shift-up never arrives once another app or window has the keyboard.
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            peekObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endPeek() }
            })
        }
        peekLinkTarget.action = { [weak self] in MainActor.assumeIsolated { self?.peekStep() } }
    }

    private func peekFlagsChanged(_ event: NSEvent) {
        guard let peek else { return }
        let now = CACurrentMediaTime()
        if OrbitSCNView.peekHeld(event.modifierFlags), canStartPeek(event) {
            peek.layout = peekLayout()
            peek.press(at: now)
            if peek.state.wantsCamera { startPeekLink() }
        } else {
            peek.release(at: now)
        }
    }

    /// Shift over this viewer, in the key window, not while typing.
    private func canStartPeek(_ event: NSEvent) -> Bool {
        guard let window = scnView.window, window.isKeyWindow, event.window === window,
              !(window.firstResponder is NSText) else { return false }
        let p = scnView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return scnView.bounds.contains(p)
    }

    private func endPeek() {
        peek?.release(at: CACurrentMediaTime())
    }

    /// The view on the glass, if the window is on the built-in display (where the webcam is).
    private func peekLayout() -> HeadGeometry.Layout? {
        guard let window = scnView.window, let screen = window.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              CGDisplayIsBuiltin(id) != 0 else { return nil }
        let rect = window.convertToScreen(scnView.convert(scnView.bounds, to: nil))
        return HeadGeometry.layout(viewRect: rect, screenFrame: screen.frame, screenSizeMM: CGDisplayScreenSize(id))
    }

    private func startPeekLink() {
        guard peekLink == nil else { return }
        let link = scnView.displayLink(target: peekLinkTarget, selector: #selector(LinkTarget.fire))
        link.add(to: .main, forMode: .common)
        peekLink = link
    }

    private func stopPeekLink() {
        peekLink?.invalidate()
        peekLink = nil
    }

    private func peekStep() {
        guard let peek else { return stopPeekLink() }
        let now = CACurrentMediaTime()
        peek.layout = peekLayout()
        if peek.layout == nil { peek.release(at: now) }  // moved off the built-in display
        // A Shift-up eaten by a tracking loop (live resize, a menu) never reaches the monitor.
        if !OrbitSCNView.peekHeld(NSEvent.modifierFlags) { peek.release(at: now) }
        peek.tick(at: now)
        applyCamera()  // the last call, at blend 0, puts the normal camera back
        if peek.blend == 0 { stopPeekLink() }
    }

    // MARK: Mouse and trackpad

    private func handle(_ input: OrbitSCNView.Input) {
        switch input {
        case .orbitBegan(let location):
            pivot = pointUnder(location)
            return
        case .orbit(let dx, let dy):
            orbit.orbit(dx: dx, dy: dy, about: pivot)
        case .focus(let location):
            focus(at: location)
            return
        case .pan(let dx, let dy):
            orbit.pan(dx: dx, dy: dy, viewHeight: Double(scnView.bounds.height))
        case .hover(let location):
            if !isPeeking, onEditHover != nil || onHover != nil {
                let pointer = editPointer(at: location)
                onEditHover?(pointer)
                onHover?(pointer)
            }
            return
        case .zoom(let factor, let location, let phase):
            if phase == .began || phase == .discrete || gestureAnchor == nil {
                gestureAnchor = pointUnder(location)
            }
            if let anchor = gestureAnchor { orbit.zoom(factor: factor, about: anchor) }
            if phase == .ended || phase == .cancelled || phase == .discrete { gestureAnchor = nil }
        }
        applyCamera()
    }

    /// The nearest thing shown under a view location: the model (parts,
    /// isosurfaces, object, car) or the slice. nil over empty space.
    private func surfacePoint(_ location: CGPoint) -> SIMD3<Double>? {
        let options: [SCNHitTestOption: Any] = [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true]
        let hits = [modelRoot, sliceNode].compactMap { root in
            scnView.hitTest(location, options: options.merging([.rootNode: root]) { $1 }).first
        }
        return hits.map { SIMD3<Double>($0.simdWorldCoordinates) }
            .min { simd_distance($0, orbit.position) < simd_distance($1, orbit.position) }
    }

    /// The surface point under a view location, or the target plane there.
    private func pointUnder(_ location: CGPoint) -> SIMD3<Double> {
        if let p = surfacePoint(location) { return p }
        // The off-axis view does not match pointOnTargetPlane's maths: use the target.
        if isPeeking { return orbit.target }
        let size = scnView.bounds.size
        let ndc = SIMD2<Double>(Double(location.x / max(size.width, 1)) * 2 - 1, Double(location.y / max(size.height, 1)) * 2 - 1)
        return orbit.pointOnTargetPlane(ndc: ndc, aspect: aspect)
    }

    /// Double-click (or trackpad smart zoom): centre the view on the surface
    /// point there, keeping the distance; over empty space, fit everything.
    private func focus(at location: CGPoint) {
        guard let p = surfacePoint(location) else { return fitAll() }
        let shift = p - orbit.target
        orbit.position += shift
        orbit.target += shift
        applyCamera()
    }

    // MARK: Picking and markers

    private func editPointer(at p: CGPoint) -> EditPointer {
        let hit = scnView.hitTest(p, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true, .rootNode: modelRoot,
        ]).first
        let pick = hit.map { h -> PickResult in
            let w = h.simdWorldCoordinates
            return PickResult(point: SIMD3(Double(w.x), Double(w.y), Double(w.z)), nodeID: h.node.name.flatMap { Int($0) },
                              snapped: false, faceIndex: h.faceIndex)
        }
        return EditPointer(screen: SIMD2(Double(p.x), Double(p.y)), hit: pick)
    }

    /// Like projectToScreen, with the depth (0 near, 1 far) in z.
    public func projectWithDepth(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let v = scnView.projectPoint(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
        return SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    /// A world point (metres) in view points, origin bottom left, as clicks report.
    public func projectToScreen(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let v = scnView.projectPoint(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
        return SIMD2(Double(v.x), Double(v.y))
    }

    /// Edit mode's drawing over the part: every edge thin, the hovered ones
    /// brighter, the picked ones in sage, and the points placed so far.
    /// `hoverFaces` and `selectedFaces` are triangle corners, three per triangle, world space:
    /// the face under the pointer tinted light, the picked ones sage.
    public func setEditOverlay(edges: [[SIMD3<Double>]], highlighted: Set<Int>, selected: Set<Int>, points: [SIMD3<Double>],
                               hoverFaces: [SIMD3<Double>] = [], selectedFaces: [SIMD3<Double>] = []) {
        editRoot.childNodes.forEach { $0.removeFromParentNode() }
        func tint(_ corners: [SIMD3<Double>], _ color: NSColor) {
            guard corners.count >= 3 else { return }
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.isDoubleSided = true
            m.readsFromDepthBuffer = true
            m.writesToDepthBuffer = false
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: corners.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) })],
                                elements: [SCNGeometryElement(indices: (0..<Int32(corners.count - corners.count % 3)).map { $0 }, primitiveType: .triangles)])
            g.materials = [m]
            let node = SCNNode(geometry: g)
            node.renderingOrder = 99
            editRoot.addChildNode(node)
        }
        tint(selectedFaces, NSColor(red: 0.59, green: 0.72, blue: 0.5, alpha: 0.55))
        tint(hoverFaces, NSColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 0.35))
        func lines(_ ids: [Int], _ color: NSColor, order: Int) {
            var vertices: [SCNVector3] = [], indices: [Int32] = []
            for k in ids where edges[k].count > 1 {
                let base = Int32(vertices.count)
                vertices += edges[k].map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
                for j in 0..<Int32(edges[k].count - 1) { indices += [base + j, base + j + 1] }
            }
            guard !indices.isEmpty else { return }
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.readsFromDepthBuffer = order > 0
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
            g.materials = [m]
            let node = SCNNode(geometry: g)
            node.renderingOrder = 100 + order
            editRoot.addChildNode(node)
        }
        let all = Array(edges.indices)
        lines(all.filter { !highlighted.contains($0) && !selected.contains($0) }, NSColor(white: 0.1, alpha: 0.6), order: 1)
        lines(all.filter { highlighted.contains($0) && !selected.contains($0) }, NSColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1), order: 2)
        lines(Array(selected), NSColor(red: 0.59, green: 0.72, blue: 0.5, alpha: 1), order: 3)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(red: 0.9, green: 0.69, blue: 0.31, alpha: 1)
        m.readsFromDepthBuffer = false
        for p in points {
            let sphere = SCNSphere(radius: CGFloat(radius * 0.006))
            sphere.materials = [m]
            let node = SCNNode(geometry: sphere)
            node.simdPosition = SIMD3(Float(p.x), Float(p.y), Float(p.z))
            node.renderingOrder = 104
            editRoot.addChildNode(node)
        }
    }

    private func handleClick(_ gesture: NSClickGestureRecognizer) {
        if isPeeking { return }  // peeking is for looking; a pick would land off the normal view
        if let onEditClick, model != nil {
            onEditClick(editPointer(at: gesture.location(in: scnView)))
            return
        }
        if let onClickPointer, model != nil {
            onClickPointer(editPointer(at: gesture.location(in: scnView)))
            return
        }
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
        setMeasureOverlay(lines: points.count == 2 ? [points] : [], points: points, hover: nil)
    }

    /// The measure tool's drawing, over the model: finished and in-progress
    /// lines and points in red, the snap under the pointer in amber.
    public func setMeasureOverlay(lines: [[SIMD3<Double>]], points: [SIMD3<Double>], hover: SIMD3<Double>?) {
        markerRoot.childNodes.forEach { $0.removeFromParentNode() }
        func material(_ color: NSColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.readsFromDepthBuffer = false
            return m
        }
        let red = material(NSColor(red: 0.85, green: 0.2, blue: 0.15, alpha: 1))
        func dot(_ p: SIMD3<Double>, _ m: SCNMaterial, _ size: Float) {
            let sphere = SCNSphere(radius: CGFloat(radius * size))
            sphere.materials = [m]
            let node = SCNNode(geometry: sphere)
            node.simdPosition = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            node.renderingOrder = 100
            markerRoot.addChildNode(node)
        }
        for p in points { dot(p, red, 0.006) }
        var vertices: [SCNVector3] = [], indices: [Int32] = []
        for line in lines where line.count > 1 {
            let base = Int32(vertices.count)
            vertices += line.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            for j in 0..<Int32(line.count - 1) { indices += [base + j, base + j + 1] }
        }
        if !indices.isEmpty {
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
            g.materials = [red]
            let node = SCNNode(geometry: g)
            node.renderingOrder = 100
            markerRoot.addChildNode(node)
        }
        if let hover { dot(hover, material(NSColor(red: 0.95, green: 0.7, blue: 0.2, alpha: 1)), 0.008) }
    }
}

// MARK: Overlays: frame box, points, slice

extension SceneKitViewer {
    /// Polylines drawn over the model in amber, never hidden behind it: a
    /// proposed repair. An empty array clears them.
    public func setPreviewLines(_ polylines: [[SIMD3<Double>]]) {
        previewRoot.childNodes.forEach { $0.removeFromParentNode() }
        var vertices: [SCNVector3] = [], indices: [Int32] = []
        for line in polylines where line.count > 1 {
            let base = Int32(vertices.count)
            vertices += line.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            for k in 0..<Int32(line.count - 1) { indices += [base + k, base + k + 1] }
        }
        guard !indices.isEmpty else { return }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.systemOrange
        material.readsFromDepthBuffer = false
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 101
        previewRoot.addChildNode(node)
    }
}

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
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = max(1, pointSize / 3)
        element.maximumPointScreenSpaceRadius = pointSize * 2
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        pointsNode.geometry = geometry
    }

    public func setSlice(_ image: CGImage?, center: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) {
        sliceNode.geometry = nil
        let w = simd_length(right), h = simd_length(up)
        guard let image, w > 0, h > 0 else { return }
        let plane = SCNPlane(width: CGFloat(w), height: CGFloat(h))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.magnificationFilter = .nearest
        material.isDoubleSided = true
        material.transparency = 0.9
        plane.materials = [material]
        sliceNode.geometry = plane
        // SCNPlane lies in its local x-y plane: local x goes along `right`,
        // local y along `up`, and the normal completes a right-handed frame.
        let r = SIMD3<Float>(right / w), u = SIMD3<Float>(up / h)
        sliceNode.simdTransform = simd_float4x4(columns: (
            SIMD4(r, 0),
            SIMD4(u, 0),
            SIMD4(simd_cross(r, u), 0),
            SIMD4(SIMD3<Float>(center), 1)
        ))
    }
}

/// SCNView that turns mouse and trackpad input into camera moves. Orbits
/// pivot about the point under the cursor where the drag or gesture began.
///   drag (or shift-drag while peeking): orbit        option-drag, right-drag, middle-drag: pan
///   pinch: zoom at the cursor        mouse wheel or command-scroll: zoom at the cursor
///   two-finger scroll on a trackpad: pan        trackpad rotate: turn about the up axis
///   double-click or two-finger double-tap: centre on the point (empty space: fit)
final class OrbitSCNView: SCNView {
    enum Phase { case discrete, began, changed, ended, cancelled }

    enum Input {
        case orbitBegan(at: CGPoint)
        case orbit(dx: Double, dy: Double)
        case focus(at: CGPoint)
        case pan(dx: Double, dy: Double)
        case zoom(factor: Double, at: CGPoint, phase: Phase)
        case hover(at: CGPoint)
    }

    var onInput: ((Input) -> Void)?
    private var last: CGPoint?
    private var panning = false

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onInput?(.hover(at: location(event))) }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = location(event)
        last = p
        panning = Self.dragPans(event.modifierFlags)
        if !panning { onInput?(.orbitBegan(at: p)) }
    }

    /// Option-drag pans. Shift is left free for the head-tracked peek.
    static func dragPans(_ flags: NSEvent.ModifierFlags) -> Bool { flags.contains(.option) }

    /// Shift on its own (caps lock and the like aside) holds a peek; Shift with
    /// Command or Option is a shortcut, not a peek.
    static func peekHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .shift
    }

    override func mouseDragged(with event: NSEvent) { drag(event, pan: panning) }
    override func mouseUp(with event: NSEvent) { last = nil }
    override func rightMouseDown(with event: NSEvent) { last = location(event) }
    override func rightMouseDragged(with event: NSEvent) { drag(event, pan: true) }
    override func rightMouseUp(with event: NSEvent) { last = nil }
    override func otherMouseDown(with event: NSEvent) { last = location(event) }
    override func otherMouseDragged(with event: NSEvent) { drag(event, pan: true) }
    override func otherMouseUp(with event: NSEvent) { last = nil }

    private func drag(_ event: NSEvent, pan: Bool) {
        let p = location(event)
        defer { last = p }
        guard let l = last else { return }
        let dx = Double(p.x - l.x), dy = Double(p.y - l.y)
        onInput?(pan ? .pan(dx: dx, dy: dy) : .orbit(dx: dx, dy: dy))
    }

    /// A trackpad's two-finger scroll pans; a mouse wheel (or command-scroll) zooms.
    /// Trackpad scrolls have precise deltas and always carry a gesture or momentum
    /// phase; a smooth-scrolling mouse can send precise deltas but no phase.
    static func scrollPans(precise: Bool, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, command: Bool) -> Bool {
        precise && !command && !(phase.isEmpty && momentumPhase.isEmpty)
    }

    override func scrollWheel(with event: NSEvent) {
        if Self.scrollPans(precise: event.hasPreciseScrollingDeltas, phase: event.phase,
                           momentumPhase: event.momentumPhase, command: event.modifierFlags.contains(.command)) {
            // Same convention as a scroll view: AppKit has already applied the
            // user's natural-scrolling setting to the deltas.
            onInput?(.pan(dx: Double(event.scrollingDeltaX), dy: Double(-event.scrollingDeltaY)))
            return
        }
        // Shift turns a mouse wheel into horizontal scrolling; zoom with it all the same.
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let amount = Double(delta) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        guard amount != 0 else { return }
        onInput?(.zoom(factor: exp(-amount), at: location(event), phase: Self.phase(event.phase)))
    }

    override func rotate(with event: NSEvent) {
        if event.phase.contains(.began) { onInput?(.orbitBegan(at: location(event))) }
        // Degrees anticlockwise; the model turns with the fingers, as seen from above
        // (orbit turns 0.008 rad per point, and dragging right turns it anticlockwise).
        onInput?(.orbit(dx: Double(event.rotation) * .pi / 180 / 0.008, dy: 0))
    }

    override func smartMagnify(with event: NSEvent) { onInput?(.focus(at: location(event))) }

    override func magnify(with event: NSEvent) {
        onInput?(.zoom(factor: 1 / max(1 + Double(event.magnification), 0.05), at: location(event), phase: Self.phase(event.phase)))
    }

    private static func phase(_ p: NSEvent.Phase) -> Phase {
        if p.contains(.began) { return .began }
        if p.contains(.ended) { return .ended }
        if p.contains(.cancelled) { return .cancelled }
        if p.contains(.changed) || p.contains(.stationary) { return .changed }
        return .discrete
    }
}

/// The display link's Objective-C target.
private final class LinkTarget: NSObject {
    var action: (() -> Void)?

    @objc func fire() {
        action?()
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
