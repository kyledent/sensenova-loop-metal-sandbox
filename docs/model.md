# Model

[SenseNova Loop 9B Preview](https://huggingface.co/sensenova/SenseNova-Loop-9B-Preview), as text-only GGUF files from the
runtime fork's author, [guideboardlabs/SenseNova-Loop-9B-Preview-GGUF](https://huggingface.co/guideboardlabs/SenseNova-Loop-9B-Preview-GGUF).
Each file is pinned to a commit of that repository and to its SHA-256 checksum.

| | `Q4_K_M` | `Q4_0` | `Q3_K_M` |
|---|---|---|---|
| **Weights** | 5.63 GB | 5.33 GB | 4.64 GB |
| **Model id in pi** | `sensenova-loop-9b-q4-k-m` | `sensenova-loop-9b-q4-0` | `sensenova-loop-9b-q3-k-m` |
| **Default on** | more than 11 GB | | 11 GB or less |

The convolution kernels, norms and routers stay in FP32 in all three. The looped block is stored once, and the runtime
reuses it for the second pass, so the files are 36% smaller than storing it twice. Vision and the MTP draft head are not
in these files, so this setup is text only, without speculative decoding.

Other GGUF conversions exist, but they were made with other builds, and this fork may not load them. Use these.

## Switching

```sh
./loop models          # list them, and which is downloaded and running
./loop use Q4_0        # switch to Q4_0
./loop use 32K         # a 32K context, on the same quant
./loop use Q3_K_M 16K  # both
./loop use auto        # back to the context by RAM
./loop use cpu         # the build without the Metal patch, with the routing on the CPU
./loop use metal       # the build with it (the default)
```

To choose the context from a list, with the memory that each size needs for the selected quant, run `./loop ctx`:

```
The server serves Q4_K_M with a 16384-token context.
The GPU may use about 12 GB of this Mac's 16 GB. Estimated memory for each context:
  1)    8K  about 5.9 GB
  2)   16K  about 6.4 GB   (current, default for this Mac)
  3)   32K  about 7.2 GB
  4)   64K  about 9.0 GB
  5)  128K  about 12.5 GB   (too big)
  6)  256K  about 19.5 GB   (too big)
  a) auto: by RAM, now 16K
Choose 1-6 or a, or press Enter to keep it:
```

Your choice goes through `use`, so it is kept, and the old server comes back if the new one fails. `./loop ctx 32K`
chooses without the list. The fork's author has tested up to 16K.

`use` takes a quant, a context, and `cpu` or `metal`, in any order, and keeps the rest as it is. It:

1. warns if the setup looks too big for the Mac's memory;
2. builds and downloads what is missing, while the running server keeps serving;
3. writes the choice to `.env`, so `./loop` and every other command use it from then on;
4. restarts the server with it. If the new server does not start, `.env` and the previous server come back, and the
   failed server's log is kept in `.state/server.failed.log`.

There is nothing to set by hand. A `LOOP_QUANT` exported in your shell still wins over `.env`, so `use` tells you if
your shell sets one.

The next time pi starts, detection finds the new model and makes it the default. In a pi that is already open, run
`./loop detect` in another terminal, then pick the model in `/model`.

## Settings from the model card

- **Sampling:** temperature 1.0 and top-p 0.95, from its generation config. Top-k 50 and no min-p are transformers'
  defaults, which is how the reference samples, and llama.cpp's own defaults would differ.
- **Thinking:** its chat template turns thinking on or off, with `enable_thinking`, and has no reasoning effort. So pi's
  levels differ by thinking budget alone. See [Thinking levels](pi-integration.md#thinking-levels).
- **Tool calls:** the template's own format, `<tool_call><function=...>`, as in Qwen3.5. llama.cpp parses it with
  `--jinja`.

## Memory

The default context comes from your Mac's RAM: 8K up to 11 GB, 16K up to 23 GB, 32K up to 35 GB, 64K up to 71 GB, and
128K above that.

The KV cache is about 56 KiB per token. Only the full-attention layers keep one: 8 of the 32, 6 of them in the loop, so 14
caches. The linear-attention layers keep a fixed state instead, about 90 MiB whatever the context.

### Estimated memory by context

In GB, for the weights, the KV cache and the linear-attention state. Not measured yet.

| Context | Default on | `Q4_K_M` | `Q4_0` | `Q3_K_M` |
|---|---|---:|---:|---:|
| 8K | up to 11 GB | 6.2 | 5.9 | 5.2 |
| 16K | up to 23 GB | 6.7 | 6.4 | 5.7 |
| 32K | up to 35 GB | 7.6 | 7.3 | 6.6 |
| 64K | up to 71 GB | 9.5 | 9.2 | 8.5 |
| 128K | more | 13.2 | 12.9 | 12.3 |
| 262K | never (the limit) | 20.8 | 20.5 | 19.8 |

These leave out:

- the prompt cache, which can grow to `LOOP_CACHE_RAM`: by default a quarter of the RAM, at most 24 GiB;
- the compute buffers, a few hundred MB;
- macOS, your other apps, and pi.

macOS also limits how much memory the GPU may use, to about three quarters of the RAM. On an 8 GB Mac that is about 5.3
GB, so even `Q3_K_M` at 8K is tight there.

## What is not known yet

- **Speed on a Mac.** The fork's author measured 30 tokens/s of generation on an AMD RX 5700 XT, with Vulkan. Each token
  goes through 56 layers for 32 stored, so expect less than a 9B model's size alone suggests. `./loop bench` measures
  your Mac, with the [Metal kernels](metal.md) or without them.
- **Long contexts.** The model was trained up to 262K. The fork's author tested to 16K.
- **Accuracy of the fork.** Its greedy output matches the reference implementation token for token on one short prompt.
  No perplexity or KL comparison has been run on these quants.
- **How it does as a coding agent.** The model card describes it as made for agentic work, and its template supports tool
  calls. It has been tested here with a mock server only.
