import MRICore
import SceneKit
import SwiftUI
import simd

enum MeshScene {
    /// SceneKit geometry with smooth per-vertex normals.
    static func geometry(_ m: Mesh) -> SCNGeometry {
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
        mat.diffuse.contents = NSColor(calibratedRed: 0.93, green: 0.78, blue: 0.74, alpha: 1)
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
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = Double(size) * 10
        // Look from the front-left, slightly above.
        cam.position = SCNVector3(-size * 0.9, size * 0.5, size * 1.6)
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
        return scene
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
