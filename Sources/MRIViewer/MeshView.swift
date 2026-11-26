import MRICore
import SceneKit
import SwiftUI
import simd

enum MeshScene {
    /// SceneKit geometry with smooth per-vertex normals.
    static func geometry(_ m: Mesh, color: NSColor = NSColor(calibratedRed: 0.93, green: 0.78, blue: 0.74, alpha: 1)) -> SCNGeometry {
        var normals = [SIMD3<Float>](repeating: .zero, count: m.vertices.count)
        for t in stride(from: 0, to: m.triangles.count, by: 3) {
            let a = Int(m.triangles[t]), b = Int(m.triangles[t + 1]), c = Int(m.triangles[t + 2])
            let n = simd_cross(m.vertices[b] - m.vertices[a], m.vertices[c] - m.vertices[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        for i in normals.indices {
            let l = simd_length(normals[i])
            normals[i] = l > 0 ? normals[i] / l : SIMD3(0, 0, 1)
        }
        let vData = m.vertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let nData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let vs = SCNGeometrySource(data: vData, semantic: .vertex, vectorCount: m.vertices.count, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let ns = SCNGeometrySource(data: nData, semantic: .normal, vectorCount: normals.count, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let idx = m.triangles.withUnsafeBufferPointer { Data(buffer: $0) }
        let el = SCNGeometryElement(data: idx, primitiveType: .triangles, primitiveCount: m.triangleCount, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [vs, ns], elements: [el])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .blinn
        mat.specular.contents = NSColor(white: 0.25, alpha: 1)
        g.materials = [mat]
        return g
    }

    static func scene(_ m: Mesh) -> SCNScene {
        let scene = SCNScene()
        let node = SCNNode(geometry: geometry(m))
        // Model is in RAS mm sitting on z = 0; SceneKit is y-up, so rotate z-up → y-up.
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        let (lo, hi) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        scene.rootNode.addChildNode(node)
        addCameraAndLights(scene, size: max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z))
        return scene
    }

    static func addCameraAndLights(_ scene: SCNScene, size: CGFloat) {
        scene.background.contents = NSColor.black
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = Double(size) * 10
        // Model frame RAS rotated z-up → y-up maps anterior (+y) to SceneKit −z: look from the front-left, slightly above.
        cam.position = SCNVector3(-size * 0.9, size * 0.5, -size * 1.6)
        cam.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cam)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.6, -0.5, 0)
        scene.rootNode.addChildNode(key)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 350
        scene.rootNode.addChildNode(amb)
    }
}

struct MeshView: NSViewRepresentable {
    let mesh: Mesh
    let token: Int

    final class Coordinator { var token = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = false
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        guard context.coordinator.token != token else { return }
        context.coordinator.token = token
        v.scene = MeshScene.scene(mesh)
        v.pointOfView = v.scene?.rootNode.childNodes.first { $0.camera != nil }
    }
}

/// Scene for a print kit: parts coloured, head translucent; `apply` sets the exploded layout.
final class KitScene {
    let scene = SCNScene()
    var nodes: [(node: SCNNode, offset: SCNVector3, group: String)] = []

    static func build(_ kit: KitResult) -> KitScene {
        let k = KitScene()
        let root = SCNNode()
        root.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0) // z-up → y-up
        k.scene.rootNode.addChildNode(root)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in kit.parts { if let b = MeshOps.bounds(p.mesh) { lo = simd_min(lo, b.min); hi = simd_max(hi, b.max) } }
        let centre = (lo + hi) / 2
        for p in kit.parts {
            let col = NSColor(calibratedRed: CGFloat(p.color.x), green: CGFloat(p.color.y), blue: CGFloat(p.color.z), alpha: 1)
            let node = SCNNode(geometry: MeshScene.geometry(p.mesh, color: col))
            if p.group == "head" {
                node.opacity = 0.22
                node.geometry?.firstMaterial?.isDoubleSided = true
                node.renderingOrder = 10
            }
            guard let b = MeshOps.bounds(p.mesh) else { continue }
            var dir = (b.min + b.max) / 2 - centre
            if p.group == "head" { dir = SIMD3(0, 0, p.name.hasSuffix("top") ? 90 : -30) } // lift the cap
            if p.group == "eye" { dir = simd_normalize(dir) * 60 }
            node.pivot = SCNMatrix4MakeTranslation(CGFloat(centre.x), CGFloat(centre.y), CGFloat(centre.z))
            root.addChildNode(node)
            k.nodes.append((node, SCNVector3(CGFloat(dir.x), CGFloat(dir.y), CGFloat(dir.z)), p.group))
        }
        MeshScene.addCameraAndLights(k.scene, size: CGFloat(simd_reduce_max(hi - lo)))
        return k
    }

    static func apply(_ k: KitScene, explode: Double, showHead: Bool) {
        for (node, off, group) in k.nodes {
            let f = CGFloat(explode) * (group == "head" ? 1 : 0.6)
            node.position = SCNVector3(off.x * f, off.y * f, off.z * f)
            node.isHidden = group == "head" && !showHead
        }
    }
}

/// Multi-part kit preview with an exploded-view slider.
struct KitView: NSViewRepresentable {
    let kit: KitResult
    let token: Int
    let explode: Double
    let showHead: Bool

    final class Coordinator { var token = -1; var scene: KitScene? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        if c.token != token {
            c.token = token
            let k = KitScene.build(kit)
            c.scene = k
            v.scene = k.scene
            v.pointOfView = k.scene.rootNode.childNodes.first { $0.camera != nil }
        }
        if let k = c.scene { KitScene.apply(k, explode: explode, showHead: showHead) }
    }
}
