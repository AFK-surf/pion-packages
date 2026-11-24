// Metal GPU runner for the packages/wgsl red-team audit.
//   gpurun <file.metal> <kernel> <threads> <slot>=<hex-bytes> ...
// Compiles the MSL at runtime, binds each hex buffer at [[buffer(slot)]], dispatches <threads> threads
// (one threadgroup) and prints `<slot>=<hex-bytes>` for every buffer after completion, or `ERROR <reason>`.
import Foundation
import Metal

func hexToData(_ s: String) -> [UInt8] {
  var out: [UInt8] = []
  var i = s.startIndex
  while i < s.endIndex {
    let j = s.index(i, offsetBy: 2)
    out.append(UInt8(s[i..<j], radix: 16)!)
    i = j
  }
  return out
}

let args = CommandLine.arguments
guard args.count >= 4, let device = MTLCreateSystemDefaultDevice() else {
  print("ERROR usage-or-no-device")
  exit(2)
}
let src = try! String(contentsOfFile: args[1], encoding: .utf8)
let opts = MTLCompileOptions()
opts.languageVersion = .version2_4
let lib: MTLLibrary
do { lib = try device.makeLibrary(source: src, options: opts) } catch {
  print("ERROR compile \(error.localizedDescription.prefix(200))")
  exit(1)
}
guard let fn = lib.makeFunction(name: args[2]) else { print("ERROR no-function"); exit(1) }
let pso = try! device.makeComputePipelineState(function: fn)
let threads = Int(args[3])!
var bufs: [(Int, MTLBuffer)] = []
for spec in args.dropFirst(4) {
  let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
  var bytes = hexToData(parts[1])
  let b = device.makeBuffer(bytes: &bytes, length: bytes.count, options: .storageModeShared)!
  bufs.append((Int(parts[0])!, b))
}
let q = device.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso)
for (slot, b) in bufs { enc.setBuffer(b, offset: 0, index: slot) }
enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
enc.endEncoding()
cb.commit()
cb.waitUntilCompleted()
if let e = cb.error { print("ERROR gpu \(e.localizedDescription.prefix(200))"); exit(1) }
for (slot, b) in bufs {
  let p = b.contents().bindMemory(to: UInt8.self, capacity: b.length)
  var s = ""
  for k in 0..<b.length { s += String(format: "%02x", p[k]) }
  print("\(slot)=\(s)")
}
