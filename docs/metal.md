# Metal

The fork adds two operations to ggml for the model's routing: `ggml_mhc_route` and `ggml_mhc_merge`. Without them, each
router would be about 110 small operations, and the graph would not fit llama.cpp's node budget. The fork implements
them for the CPU and as Vulkan shaders, but not for Metal. So on a Mac, llama.cpp would run them on the CPU, handing
their inputs over and the results back about a hundred times per token: 48 layer passes in the loop, each with two
routed sublayers.

This repository adds the Metal kernels, as a patch that `./loop setup` applies to the fork before it builds:
[`patches/0001-metal-mhc-route-and-merge.patch`](../patches/0001-metal-mhc-route-and-merge.patch).

## What the patch does

- **`kernel_mhc_route_f32`:** one threadgroup per token and stream. Its threads read the two streams and the router's
  weights once, and reduce the RMS norm and the eight logits with `simd_sum`. One thread then computes the four gates
  and the twenty Sinkhorn passes over the 2x2 mixing matrix, in log space, as trained.
- **`kernel_mhc_merge_f32`:** elementwise. It mixes the two streams with the matrix, and adds the gated sublayer output.
- **`supports_op`:** both stay on the GPU whenever their inputs are float32 with contiguous rows, as in the model, and fall
  back to the CPU otherwise.
- **`test-backend-ops`:** 16 new cases compare the two kernels with the CPU's at the model's width (4096), for one token
  and for a batch, at an odd width, with the streams as views of one buffer as in the model, and with two streams.

The kernels follow the fork's CPU implementation, which is the reference. They differ from its Vulkan shader in one way:
the shader computes the router's logits from the first stream only and uses them for every stream, while the CPU
computes them for each. The two agree when there is one stream, as in the model, and the Metal kernels follow the CPU.

## How it was checked

Before it reached a Mac:

- The host code (`ggml-metal-ops.cpp`, `ggml-metal-device.cpp`) and `test-backend-ops.cpp` compile for macOS on Apple
  Silicon, with clang and `-Wall`, against the fork's headers.
- The kernels' source ran on a CPU, one thread per Metal thread with real barriers and an emulated `simd_sum`, against
  the fork's CPU implementation, with views, two streams, widths of 33 to 4096 and threadgroups of 32 to 256. Every
  output matched to within float rounding (a normalized error of at most 6e-12), and a planted bug in either kernel was
  caught. `tests/metal-kernels.sh` does this again, on any machine with a C++20 compiler, with the kernels taken out of
  the patch, and `tests/run.sh` runs it when it finds one.

What only a Mac can check: that Metal's compiler accepts the kernels, and that they run as the emulation did. Metal
compiles its kernels when the server starts, and a kernel that does not compile takes the whole Metal library with it,
so the server would find no GPU.

`./loop doctor` runs the 16 cases in the server's sandbox, and passes only if all 16 pass on Metal:

```
Server sandbox
  ok    the Metal routing kernels match the CPU's (16 of 16 cases)
```

## If it fails

```sh
./loop use cpu
```

builds the fork as it is, in a folder of its own, with the routing on the CPU, and switches the server to it. `.env`
keeps the choice. `./loop use metal` switches back, without building again. Please report the failure, with the output
of `./loop doctor` and the end of `.state/server.log`.

## Measuring it

```sh
./loop bench
```

Each result in `.state/bench.jsonl` names the build it ran on: the commit, and `-metal-` with the patch's checksum when
it is applied. So the two can be compared on the same Mac:

```sh
./loop use cpu && ./loop bench     # the routing on the CPU
./loop use metal && ./loop bench   # on Metal
```

For a rough idea of what to expect, the fork's author measured 30 tokens/s of generation on an AMD RX 5700 XT, where the
routing stays on the GPU through Vulkan.

## Upstream

The patch is meant for the fork, where it would help everyone who runs the model on a Mac. Once the fork has Metal
kernels of its own, this repository will pin that commit and drop the patch.
