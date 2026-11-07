# Metal

The fork adds two operations to ggml for the model's routing: `ggml_mhc_route` and `ggml_mhc_merge`. Without them, each
router would be about 110 small operations, and the graph would not fit llama.cpp's node budget. The fork implements
them for the CPU and as Vulkan shaders, but not for Metal.

## What happens on a Mac

The rest of the model, including the linear-attention layers, has Metal code in the llama.cpp release the fork is based
on. So llama.cpp runs the layers on the GPU, and for each routing operation hands its inputs to the CPU and the result
back. Inside the loop, every sublayer has a router: 48 layer passes with two sublayers each. So each token makes on the
order of a hundred trips between the GPU and the CPU.

It runs, and the output is the same: the operations are the same code wherever they run. But each trip waits for the GPU
to finish before the CPU can start, which costs time on every token. How much is not known yet.

`./loop doctor` notes this, and quotes the server log's graph splits if the log has them: each split is a change between
the GPU and the CPU.

## Measuring it

```sh
./loop bench
```

Each result in `.state/bench.jsonl` names the runtime's commit, so a later build, with Metal code for these operations, can
be compared with this one on the same Mac. Activity Monitor shows the split too: the GPU's use stays below what a model
of this size would reach, and the CPU's rises during generation.

For a rough idea of the cost, the fork's author measured 30 tokens/s of generation on an AMD RX 5700 XT with Vulkan,
where the routing stays on the GPU.

## Porting the operations

A Metal port means, in the fork's `ggml/src/ggml-metal/`:

1. kernels for both operations, from the Vulkan shaders (`mhc_route.comp` and `mhc_merge.comp`, about 190 lines);
2. their dispatch, in `ggml-metal-ops.cpp`;
3. a case for each in the backend's `supports_op`, so that llama.cpp keeps them on the GPU.

The CPU implementation is the reference. The fork's author checked the Vulkan shaders against it to 1.2e-7, and a Metal
port needs the same check, then a bench on the same Mac before and after. Contributions to the fork itself would help
everyone who uses it; this repository would then pin the new commit.
