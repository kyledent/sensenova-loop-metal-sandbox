# Configuration

Settings live in `.env`, which `./loop` creates from [`.env.example`](../.env.example) on first run. `.env` is
git-ignored. Values are literal, with no quotes or `$VARS`, and a variable already set in your shell wins, so this works
for one run:

```sh
LOOP_CTX=65536 ./loop restart
```

After changing a server setting, run `./loop restart`. For the quant, the context and the Metal kernels, `./loop use`
edits `.env` and restarts the server for you: see [Switching](model.md#switching).

## Model and server

| Setting | Default | Meaning |
|---|---|---|
| `LOOP_QUANT` | by RAM | `Q4_K_M`, `Q4_0` or `Q3_K_M`. Empty: `Q3_K_M` up to 11 GB, `Q4_K_M` above. See [Model](model.md) |
| `LOOP_MODEL_DIR` | `./models` | Where the GGUF files go |
| `LOOP_CTX` | by RAM | Context in tokens, up to 262144. About 56 KiB of memory per token, on top of the weights |
| `LOOP_PORTS` | `8080-8083` | Ports that detection tries and the agent may reach. The server listens on the first, on loopback only |
| `LOOP_REASONING_BUDGET` | a sixteenth of the context | Thinking budget of requests that set none, such as compaction summaries |
| `LOOP_CACHE_RAM` | a quarter of the RAM, at most 24576 | Prompt cache cap in MiB |
| `LOOP_API_KEY` | generated | Key for the server's API. If empty, one is generated on first run and kept in `.state/api-key`. The agent can read it. Other programs need it too: `curl -H "Authorization: Bearer $(cat .state/api-key)" ...` |
| `LOOP_SERVER_ARGS` | none | More `llama-server` arguments, split on spaces |
| `LOOP_START_TIMEOUT` | `300` | Seconds to wait for the server to load |
| `LOOP_CHECK_TIMEOUT` | `900` | Seconds to wait for each request of `./loop check` and `bench` |
| `LOOP_BUILD_SANDBOX` | `1` | `0` builds llama.cpp without the build's sandbox. See [Sandbox](sandbox.md#what-gets-downloaded) |
| `LOOP_METAL_PORT` | `1` | `1` builds llama.cpp with the Metal kernels for the model's routing, `0` without, with the routing on the CPU. `./loop use metal` and `./loop use cpu` set it. See [Metal](metal.md) |

The context by RAM follows the tiers of Prism ML's Bonsai-demo: 8K up to 11 GB, 16K up to 23 GB, 32K up to 35 GB, 64K up
to 71 GB, and 128K above that.

## Agent

| Setting | Default | Meaning |
|---|---|---|
| `WORKSPACE_DIR` | `./workspace` | The folder that the agent works on |
| `LOOP_AGENT_NETWORK` | `server` | `server`, `loopback` or `open`. See [Sandbox](sandbox.md#agent-network) |
| `LOOP_THINKING` | `1` | `0` turns thinking off |
| `LOOP_THINKING_LEVELS` | see [pi integration](pi-integration.md#thinking-levels) | Each level's thinking budget, as `level=budget`. List only the ones you change |
| `LOOP_MAX_OUTPUT` | 24576 with thinking, 8192 without | Largest max output for pi. Also capped at a quarter of the context |
| `GH_TOKEN` | none | Token for `gh` and git in the sandbox. The agent can read it, so use a narrow fine-grained token. Only useful with `LOOP_AGENT_NETWORK=open` |
| `PI_VERSION` | `0.73.1` | The pi release. Change it and run `./loop setup` to upgrade |

## Files

Nothing below is committed. All of it is listed in `.gitignore`.

| Path | Contents |
|---|---|
| `.env` | Your settings, which may include tokens |
| `models/` | The GGUF files |
| `.runtime/llama-src/` | The fork's source at the pinned commit, and its build |
| `.runtime/llama/` | The built llama-server and test-backend-ops, in a folder for each commit and version of the Metal patch |
| `.runtime/pi/` | pi |
| `.state/api-key` | The server's generated API key |
| `.state/home/` | The agent's home: pi's settings, sessions and whatever it installs |
| `.state/server.log` | The server's log |
| `.state/server.failed.log` | The log of the last server that `./loop use` could not start |
| `.state/env.previous` | `.env` as it was before the last `./loop use` |
| `.state/bench.jsonl` | Results of `./loop bench` |
| `workspace/` | Your projects |

To start again, stop the server and delete `.state`. To change the runtime, change `LLAMA_COMMIT` at the top of `loop`,
and run `./loop setup`, which builds the new commit in a folder of its own. A new commit may need a new version of the
Metal patch, in `patches/`; if it does not apply, setup says so, and `./loop use cpu` builds without it.
