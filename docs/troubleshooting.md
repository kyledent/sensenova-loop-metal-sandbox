# Troubleshooting

## The build fails

`./loop setup` prints cmake's and the compiler's output.

- **"no C compiler":** install the Xcode Command Line Tools: `xcode-select --install`.
- **"cmake not found":** `brew install cmake`.
- **A permission error, or "Operation not permitted":** the build's sandbox refused something your compiler needs. See
  what it refused, then allow it in [`sandbox/build.sb`](../sandbox/build.sb), or build without the sandbox once:

  ```sh
  log show --last 5m --style compact --predicate 'sender == "Sandbox"'
  LOOP_BUILD_SANDBOX=0 ./loop setup
  ```

- **"the fork's checkout is not ...":** git fetched something other than the pinned commit. Delete `.runtime/llama-src`
  and run setup again. If it happens again, do not build it.
- **A network error during the build:** the build tried to download something, which its sandbox refuses. Report it, with
  the line it failed on.

## A `./loop doctor` check fails

The profiles are the most likely cause, particularly on a macOS version they have not met. See what was refused:

```sh
log show --last 5m --style compact --predicate 'sender == "Sandbox"'
```

Then allow the path or service in [`sandbox/server.sb`](../sandbox/server.sb) or [`sandbox/agent.sb`](../sandbox/agent.sb),
as narrowly as you can.

- **"sees Metal without a sandbox" fails:** the problem is the build, or the Mac, and not the sandbox.
- **Only "sees Metal in the sandbox" fails:** the server's profile is missing something Metal needs.
- **"it can run a program at all" fails:** `sandbox-exec` could not use the profile. Run it by hand to see the error.
- **A refusal check reports "it was allowed":** the sandbox is not doing its job. Do not rely on it until that is fixed.

## The server stops while loading

`./loop up` prints the end of the log, and the whole of it is in `.state/server.log`.

- **"unknown model architecture: 'sensenova_loop'":** that is a llama-server other than the fork's. Delete `.runtime/llama`
  and run `./loop setup`.
- **Out of memory:** use a smaller context or quant, for example `./loop use Q3_K_M 16K`. See [memory](model.md#memory).
- **M5 on macOS 26.2 to 26.4:** Prism ML found an out-of-memory error in ggml's Metal backend there, with the workaround
  `GGML_METAL_TENSOR_DISABLE=1 ./loop restart`.

## Empty or cut-off answers

The model thinks before it answers, and the thinking counts against the output limit. On a small context, the limit is
small too. Use a larger context if you have the memory, or lower the thinking level. See
[the table](pi-integration.md#auto-compaction) for the limits at each context.

## It is slow

- Part of each token runs on the CPU. See [Metal](metal.md).
- Check for Low Power Mode, which throttles inference hard (System Settings, Battery).
- A long first prompt takes a while to read: `./loop bench` shows how fast your Mac reads one. Thinking at the `high`
  level can take minutes before the answer starts.
- Lower the thinking level with Shift+Tab.

## The agent cannot do something

- **npm, pip, `git push` or `curl` fail:** the default network reaches only the model. See
  [Agent network](sandbox.md#agent-network).
- **A tool is missing:** the agent's `PATH` has the system's tools, Homebrew and node, but nothing from your home folder,
  such as pyenv or nvm's other versions. Use Homebrew, or install it in the agent's home.
- **Your git identity is missing:** the agent has its own home, so set it there with `./loop shell`, then `git config
  --global user.name ...`.
- **Pasting images does not work:** the model is text only here, and the sandbox blocks the clipboard anyway.

## The wrong quant answers

`./loop` does not replace a server that is already running. Run `./loop models` to see which quant it serves, then
`./loop use Q4_0` to switch, which also keeps the choice. If it still serves the old one, your shell may export
`LOOP_QUANT`, which wins over `.env`: `use` says so, and `unset LOOP_QUANT` fixes it.

## pi shows no SenseNova Loop model

Run `./loop status` and `./loop detect`. The server has to be ready, and its model id has to contain `sensenova-loop`. A
server on a port outside `LOOP_PORTS` is not found, and the sandbox will not let the agent reach it.

## Malformed tool calls

`./loop check` warns when a test tool call comes out malformed. The model is a preview. Try again, or with thinking on.
If it happens often, report it with the request, from `.state/server.log`.
