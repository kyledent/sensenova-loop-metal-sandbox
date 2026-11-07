# Sandbox

The server and the agent run natively, each under `sandbox-exec` with its own Seatbelt profile, and so does the build of
the server. The profiles deny everything by default, and list what is allowed. Each also starts with a clean
environment, so your shell's variables do not reach them.

Run `./loop doctor` to test the server's and the agent's on your Mac. It checks that each thing that should work does,
and that each thing that should be refused is. The build's is tested by the build itself, once.

## What each one can do

| | Server ([`server.sb`](../sandbox/server.sb)) | Agent ([`agent.sb`](../sandbox/agent.sb)) | Build ([`build.sb`](../sandbox/build.sb)) |
|---|---|---|---|
| **Reads** | System files, its binary, the model folder | System files and tools, Homebrew, pi, node, its home, the workspace | System files, the compiler, Homebrew, the fork's source |
| **Writes** | The Metal caches, its log | Its home (`.state/home`), the workspace | The source and build folder (`.runtime/llama-src`), the compiler's caches |
| **Starts programs** | No | Yes, and they stay in the sandbox | Yes, and they stay in the sandbox |
| **Network** | Listens on one loopback port, connects nowhere | Set by `LOOP_AGENT_NETWORK` | None |
| **Environment** | Only what it needs, and its API key | Only what it needs, the server's API key, and `GH_TOKEN` if you set it | Only `PATH`, `HOME`, `TMPDIR` and `LANG` |

The agent cannot read or change your home folder, other volumes, `/tmp`, this repository's `.env`, pi's install, or the
sandbox profiles. Its profile also leaves out the services for the keychain, the clipboard and `open`, which would start
apps outside the sandbox.

## Agent network

| `LOOP_AGENT_NETWORK` | The agent can reach | Trade-off |
|---|---|---|
| `server` (default) | `LOOP_PORTS` on loopback | npm, pip and `git push` do not work |
| `loopback` | Any local port, and it may listen there, for dev servers | Reaches every service on your Mac |
| `open` | Everything: the internet, your local network and any VPN | It can send out anything it can read, such as the workspace and `GH_TOKEN`, and reach internal services |

The rules appear to tell only loopback from everything else, plus the port. So there is no "only github.com", and no "VPN
only" or "internet only" either, without [a proxy or a VM](hardening.md#control-the-network). Install what a project needs
yourself, or open the network for one session:

```sh
LOOP_AGENT_NETWORK=open ./loop
```

## Limits

- **`sandbox-exec` is deprecated by Apple.** It still works, but a macOS update could change it. Run `./loop doctor`
  after upgrading.
- **Anything the agent writes in the workspace is untrusted once you use it outside.** It can change `.git/hooks`,
  `.git/config`, `package.json` scripts and editor tasks, and those run with your full rights when you use git, npm or your
  editor outside the sandbox. Read the diff first.
- **The agent does not ask before it runs a command.** The sandbox limits what a bad command can reach, but within the
  workspace, a bad command can still delete your work. Use version control and keep backups.
- **It is one layer.** It does not protect against a kernel bug, or a flaw in a system service the profile allows.
- **The server's `iokit-open` is broad.** It is not narrowed to named GPU clients, because the names differ between GPU
  generations.
- **Any local process can reach the server's port, and llama-server accepts requests from any web page.** So the server
  always has an API key, which `./loop` generates on first run. Only status endpoints, such as `/health`, answer without it. A server started
  before this change has none until `./loop restart`, and `./loop doctor` checks for this.
- **Some allowed services may leak.** The default network refuses connections, but the agent can still use the system's DNS
  resolver, which may carry data out. See [Hardening](hardening.md#close-the-gaps-in-the-profiles) for this and other gaps.

## What gets downloaded

`./loop setup` runs outside the sandbox, as it has to write the files the sandboxes then read. Only the build runs in
one.

- **The runtime** is the fork's source at a pinned commit. git checks that the checkout is that commit, whose hash covers
  every file in it, then the build runs in its sandbox. If the build's sandbox refuses something the compiler needs on
  your Mac, `LOOP_BUILD_SANDBOX=0 ./loop setup` builds without it.
- **The model** is pinned to a commit of its Hugging Face repository, and verified against a SHA-256 checksum in the `loop`
  script.
- **pi** is pinned to a version, and installed by npm with install scripts turned off. Its dependencies are not
  checksummed by this repository.

## Reporting a problem

To see what a sandbox refused:

```sh
log show --last 5m --style compact --predicate 'sender == "Sandbox"'
```

If you find a way out of a sandbox, please report it privately, through the repository's security advisories, rather than
in a public issue.
