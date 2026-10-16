// power-burn: a synthetic CPU + GPU load, for checking that limits work.
//
//   power-burn --cpu 8 --gpu          8 spinning threads plus a saturated GPU
//   power-burn --gpu --seconds 30     GPU only, exit after 30 s

import Foundation
import Metal

var cpuThreads = 0
var useGPU = false
var seconds = Double.infinity

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--cpu": cpuThreads = Int(args.next() ?? "") ?? ProcessInfo.processInfo.activeProcessorCount
    case "--gpu": useGPU = true
    case "--seconds": seconds = Double(args.next() ?? "") ?? .infinity
    default:
        print("usage: power-burn [--cpu N] [--gpu] [--seconds S]")
        exit(arg == "-h" || arg == "--help" ? 0 : 2)
    }
}
if cpuThreads == 0 && !useGPU { cpuThreads = 1 }

for _ in 0..<cpuThreads {
    Thread.detachNewThread {
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        while true {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            if x == 0 { print("unreachable") }
        }
    }
}

let kernelSource = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float a = float(id) * 1e-6f, b = 1.0001f;
    for (int i = 0; i < 2048; i++) { a = fma(a, b, 0.5f); b = fma(b, a, -0.25f); a = sin(a); }
    out[id] = a + b;
}
"""

if useGPU {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("no Metal device")
    }
    let library = try device.makeLibrary(source: kernelSource, options: nil)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "burn")!)
    let width = 1 << 20
    let buffer = device.makeBuffer(length: width * 4, options: .storageModePrivate)!
    let inFlight = DispatchSemaphore(value: 2)
    Thread.detachNewThread {
        while true {
            inFlight.wait()
            let commands = queue.makeCommandBuffer()!
            let encoder = commands.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: width, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
            )
            encoder.endEncoding()
            commands.addCompletedHandler { _ in inFlight.signal() }
            commands.commit()
        }
    }
}

print("power-burn pid \(getpid()): \(cpuThreads) CPU thread(s)\(useGPU ? " + GPU" : "")")
Thread.sleep(forTimeInterval: seconds.isFinite ? seconds : .greatestFiniteMagnitude)
