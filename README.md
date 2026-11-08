# SenseNova Loop on Apple Silicon, sandboxed

Run SenseNova's [SenseNova Loop 9B Preview](https://huggingface.co/sensenova/SenseNova-Loop-9B-Preview) locally on a
Mac, and use it from the [pi](https://pi.dev) coding agent, with the model server and the agent each confined by a
macOS sandbox.

One command builds the runtime, downloads the model, starts the server, and opens pi with the model already configured:

```sh
./loop
```

## The model

SenseNova Loop is a looped transformer: it stores 32 decoder layers, and runs layers 4 to 27 twice, so each token goes
through 56 layers. Inside the loop, two residual streams are mixed by a router at every sublayer. The trunk is a Qwen3.5
hybrid, with three linear-attention layers for each full-attention one.

| Quant | Weights | Default on |
|---|---|---|
| `Q4_K_M` | 5.6 GB | Macs with more than 11 GB |
| `Q4_0` | 5.3 GB | |
| `Q3_K_M` | 4.6 GB | Macs with 8 GB |

To switch, run `./loop use Q4_0`, which downloads it if needed, restarts the server, and keeps the choice. See
[Model](docs/model.md).

This is an independent project, not affiliated with or endorsed by SenseNova, GuideboardLabs or the authors of pi. It
downloads the model and the runtime's source from their publishers, and does not redistribute them.

## Status

> [!WARNING]
> **Not run on a Mac yet.** The scripts, the pi integration and the build steps pass their tests with stubs and a mock
> server, but those tests cannot run Seatbelt, the compiler or Metal. Run `./loop doctor` and `./loop check` before you
> rely on it, and expect that some rules may need adjusting. Reports from real machines are very welcome.

- **The runtime is a new fork.** Stock llama.cpp cannot load this architecture. The only llama.cpp that can is
  [GuideboardLabs/llama.cpp-sensenova-loop](https://github.com/GuideboardLabs/llama.cpp-sensenova-loop): two commits on
  llama.cpp, with no releases, so `./loop setup` builds it from a pinned commit. Read
  [Hardening](docs/hardening.md#protect-the-supply-chain) on what that means.
- **This repository adds the Metal kernels the fork lacks.** The fork's two routing operations have CPU and Vulkan code
  only, so on a Mac llama.cpp would hand them to the CPU about a hundred times per token. `./loop setup` applies a patch
  with Metal kernels for both, checked against the fork's CPU code, and `./loop doctor` compares them on your GPU.
  `./loop use cpu` builds without it. See [Metal](docs/metal.md).
- **The model is a preview.** Its author validated the fork against the reference implementation on one prompt, up to a
  16K context.

## Why

- **The model needs a special runtime,** which no app ships yet, and which has to be built.
- **Docker on a Mac cannot reach the GPU.** So the usual way to contain a coding agent would mean giving up Metal. Here,
  everything runs natively under `sandbox-exec` instead.
- **A coding agent runs the commands a model writes.** In its sandbox, the agent can work on one folder, but it cannot
  read your home folder, your keychain or your shell's secrets, and by default it can connect only to the model.
- **The build runs the fork's code.** So it runs in a sandbox too, with no network.

## Requirements

- A Mac with Apple Silicon, 16 GB of memory or more for a useful context (8 GB is tight), and about 8 GB of disk.
- The Xcode Command Line Tools: `xcode-select --install`
- cmake, Node 20.6 or newer, and jq: `brew install cmake node jq`

## Quick start

```sh
git clone https://github.com/kyledent/sensenova-loop-metal-sandbox.git
cd sensenova-loop-metal-sandbox
./loop setup     # build the runtime, download the model and pi, and verify them
./loop up        # start the server
./loop doctor    # check that the sandboxes allow and refuse what they should
./loop check     # check that the server serves pi correctly
./loop bench     # measure its speed
./loop           # open pi
```

The build takes a few minutes. Put your projects in `./workspace`, or set `WORKSPACE_DIR` in `.env`. The agent can only
work there.

## Commands

| Command | What it does |
|---|---|
| `./loop` | Set up if needed, start the server, open pi. Arguments go to pi. |
| `./loop setup` | Check the tools, build the runtime, and download the selected quant and pi |
| `./loop models` | List the quants, and which are downloaded and running |
| `./loop use Q4_0` | Switch the quant, the context, or `cpu` or `metal` for the routing, and keep the choice. Brings the old server back if the new one fails |
| `./loop ctx` | Choose the context size from a list, with the memory each needs on this Mac |
| `./loop up` / `down` / `restart` | Start or stop the server |
| `./loop status` / `logs` | See what is running, and follow the server's log |
| `./loop detect` | List the servers that the agent can see |
| `./loop shell` | Open a shell in the agent's sandbox |
| `./loop doctor` | Test the sandboxes |
| `./loop check` | Test that the server serves pi correctly: thinking, tool calls, long prompts, overflow and compaction |
| `./loop bench` | Measure prefill and generation speed |

## Documentation

- [Model](docs/model.md): the quants, memory, and what is not known yet
- [Metal](docs/metal.md): the Metal kernels for the model's routing, how they were checked, and how to measure them
- [Configuration](docs/configuration.md): every setting in `.env`
- [pi integration](docs/pi-integration.md): model detection, thinking levels and auto-compaction
- [Sandbox](docs/sandbox.md): what each sandbox allows, and its limits
- [Hardening](docs/hardening.md): known gaps, and how to tighten the setup further
- [Checks and benchmarks](docs/checks.md): testing the running server, and measuring its speed
- [Troubleshooting](docs/troubleshooting.md): failed checks, builds and memory

## Tests

`tests/run.sh` runs `./loop`, detection and the pi extension with a mock server and the real pi, on any machine with
bash, curl, jq, node and python. It stubs macOS's tools, git and cmake, so only `./loop setup` tests the build, and only
`./loop doctor` the sandboxes and the Metal kernels on a GPU. With a C++20 compiler, it also runs the Metal kernels on
the CPU against the fork's CPU code (`tests/metal-kernels.sh`).

```sh
npm install --prefix /tmp/pi @mariozechner/pi-coding-agent@0.73.1
tests/run.sh /tmp/pi/node_modules/@mariozechner/pi-coding-agent/dist/cli.js
```

## Acknowledgements

SenseNova Loop is by [SenseNova](https://huggingface.co/sensenova), under Apache 2.0. The llama.cpp fork and the GGUF files
are by [GuideboardLabs](https://github.com/GuideboardLabs). The Metal patch is this repository's, under the same MIT
license as llama.cpp, so that it can go upstream. This repository started from
[bonsai-metal-sandbox](https://github.com/kyledent/bonsai-metal-sandbox), which does the same for Prism ML's Ternary
Bonsai 2.

## License

[Apache License 2.0](LICENSE). This covers the code in this repository, except `patches/`, which changes llama.cpp and
is under llama.cpp's MIT license. The model, the runtime and pi are downloaded from their publishers, under their own
licenses.
