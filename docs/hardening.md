# Hardening

The default [sandbox](sandbox.md) keeps a coding agent away from your home folder, your keychain and the internet. This
page covers how to go further: settings you can change today, known gaps in the profiles and how to close them, and
stronger boundaries for work you trust less.

> [!WARNING]
> Nothing on this page has been run on a Mac yet. The gaps come from reading the profiles, so each one has a test to show
> whether it is real on your machine. Run `./loop doctor` after every change.

## What this defends against

The main risk is the agent running a harmful command without anyone intending it. It does not ask before it runs one, and
its instructions can come from anything it reads: a README, an issue, a dependency, or a web page you pasted in. So assume
that a hostile command will run at some point, and consider what it could reach.

| An attacker would want to | What stands in the way |
|---|---|
| Read your SSH keys, tokens and documents | The agent's file allow list |
| Send out what it can read | The network rules |
| Run something outside the sandbox | The `exec` and service rules, and you, when you later use the workspace |
| Stay around for later sessions | Little: see [Separate your projects](#separate-your-projects) |
| Damage the workspace, or use up the Mac's resources | Little: see [Limit the damage](#limit-the-damage) |

## Start here

These need no code changes. In `.env`:

```sh
LOOP_AGENT_NETWORK=server
LOOP_PORTS=8080
LOOP_SERVER_ARGS=--no-slots
```

- **`LOOP_AGENT_NETWORK=server`** is the default, and the most important one. Open the network for a single session only
  when you need it.
- **`LOOP_PORTS=8080`** narrows the agent's access to one port. By default it can reach 8080-8083, including anything
  else you run on those ports.
- **The API key** is on by default: `./loop` generates one, which stops other local processes and web pages from using
  the model. The agent can still read it. To rotate it, delete `.state/api-key` and run `./loop restart`.
- **`--no-slots`** turns off the server's slot monitoring, which pi does not use. The browser interface is already off:
  the build leaves it out, and `./loop up` passes `--no-webui`.

And leave `GH_TOKEN` unset. If you do need it, use a fine-grained token limited to one repository, with a short expiry, and
assume the agent can read it.

## Separate your projects

**Give the agent a copy, not your repository.** The agent can write `.git/config` and `.git/hooks` in the workspace, and
ordinary commands outside the sandbox act on them. Even `git diff` can run a program named in `.git/config`. Keep your real
repository outside the workspace, and move work across with `git clone --no-local` and `git fetch`, which git's
documentation treats as safe with a repository you do not trust:

```sh
git clone --no-local ~/code/project workspace/project   # the agent's copy

# after the agent has committed its work, from your real repository:
cd ~/code/project
git fetch /path/to/workspace/project HEAD
git diff HEAD...FETCH_HEAD
```

This protects your git setup only. Build scripts, `package.json`, `.envrc`, `Makefile` and editor tasks in the diff still
run with your full rights once you use them, so read them first.

**Use one workspace per project.** Point `WORKSPACE_DIR` at one project, not at a folder holding all of them, and keep
secrets out of it. The agent can read a `.env` in the workspace.

**Reset the agent's home between projects you do not trust.** `.state/home` is writable and survives between sessions,
including pi's extensions and settings, and pi loads them the next time it starts. Something hostile can stay there and
follow you to the next project, still inside the sandbox. With pi closed, delete it. `./loop` recreates it:

```sh
rm -rf .state/home
```

## Close the gaps in the profiles

In rough order of importance. Each test runs in `./loop shell`.

| Gap | Test | Refused if |
|---|---|---|
| [DNS can carry data out](#dns-can-carry-data-out) | `node -e 'require("dns").lookup("example.com",console.log)'` | It prints an error |
| [The agent shares your terminal](#the-agent-shares-your-terminal) | `python3 -c 'import fcntl,termios; fcntl.ioctl(0, termios.TIOCSTI, b"#")'` | It raises an error, and no `#` appears at your prompt |
| [Homebrew's data is readable](#reads-are-wider-than-they-need-to-be) | `ls /opt/homebrew/var` | It says "Operation not permitted" |
| [Your apps' preferences may be readable](#your-apps-preferences-may-be-readable) | `defaults read com.apple.dock` | It finds nothing |
| [Any file's existence shows](#file-names-and-sizes-show-everywhere) | `stat /Users/$USER/.ssh` | It says "Operation not permitted" |

### DNS can carry data out

`agent.sb` lets the agent use `com.apple.dnssd.service`, the system's DNS resolver. The resolver runs outside the sandbox,
so even with the default network, a lookup of `<your-secret>.attacker.example` may reach the attacker's name server.
`com.apple.trustd` is similar: it can fetch certificate status from addresses named in a certificate.

Neither is needed to reach the model, as detection connects to `127.0.0.1`. To allow them only with an open network, delete
those three names from `sandbox/agent.sb`, and add this to the `open` case of `render_agent_profile` in `loop`:

```sh
echo '(allow mach-lookup (global-name "com.apple.dnssd.service") (global-name "com.apple.trustd") (global-name "com.apple.trustd.agent"))'
```

### The agent shares your terminal

The agent holds your real terminal, and is allowed `ioctl` calls on it. On Linux, this was the basis of a sandbox escape,
[CVE-2017-5226](https://cve.circl.lu/cve/CVE-2017-5226): the `TIOCSTI` call types characters into the terminal's input, and
your shell runs them after the sandboxed program exits. Whether macOS allows this here has not been tested. The test above
answers that.

The fix is to give the agent a terminal of its own, with `script` relaying between the two, outside the sandbox:

```sh
script -q /dev/null env -i ... "$SANDBOX_EXEC" ...
```

`render_agent_profile` also has to run inside `script`, as the profile names the terminal, and the new one's name is not
known before that.

Output is a separate route: text the model writes reaches your terminal, and escape sequences in it can do things such as
set the clipboard. Turn off clipboard access for applications in your terminal's settings.

### Reads are wider than they need to be

`agent.sb` allows all of `/opt`, and Homebrew keeps more than programs there: `/opt/homebrew/var` holds the data of services
such as PostgreSQL and Redis. List what tools need instead:

```scheme
(subpath "/opt/homebrew/bin")
(subpath "/opt/homebrew/sbin")
(subpath "/opt/homebrew/lib")
(subpath "/opt/homebrew/opt")
(subpath "/opt/homebrew/Cellar")
(subpath "/opt/homebrew/share")
```

Programs that use TLS may also need `/opt/homebrew/etc/ca-certificates` or `/opt/homebrew/etc/openssl@3`.

`/Library` is broad in the same way. It holds settings and support files of installed apps. Narrow it to what your tools
need, such as `/Library/Developer/CommandLineTools`, using the refusals in the system log as your guide.

### Your apps' preferences may be readable

`user-preference-read` and `com.apple.cfprefsd.*` let the agent ask the preferences service for values, and that service
runs outside the sandbox. Some apps keep account names or tokens there. Remove all three, run `./loop doctor`, and if tools
fail, allow shared preferences only:

```scheme
(allow user-preference-read (preference-domain "kCFPreferencesAnyApplication"))
```

### Other services the agent may not need

`com.apple.FSEvents` may reveal activity in folders outside the sandbox, `com.apple.system.notification_center` can pass
signals between processes in and out of it, and `com.apple.analyticsd` and `com.apple.diagnosticd` are not needed for the
agent's work. Remove them one at a time and see what breaks. Also look through Apple's baseline, which the profiles import,
at `/System/Library/Sandbox/Profiles/system.sb`.

### File names and sizes show everywhere

`(allow file-read-metadata)` lets the agent check whether a file exists anywhere, with its size and date, if it can guess the
name. It cannot read the contents. Programs check the parent folders of the paths they use, so narrowing this takes some
trial and error. On most Macs this is an acceptable leak.

### The server

The server is less exposed than the agent, as it runs no commands. It does parse model files and requests, so a flaw there
is the risk.

- **Its temporary folders are shared.** `CACHE_DIR` and `TEMP_DIR` are your user's whole cache and temporary folders, which
  your other apps use as well. Point `TMPDIR` and `TEMP_DIR` at a folder of the server's own, such as `.state/server-tmp`, and
  narrow `CACHE_DIR` to the Metal shader cache, which the system log's refusals will show.
- **`iokit-open` is unrestricted.** Try listing user clients, and add others from the log:

  ```scheme
  (allow iokit-open (iokit-user-client-class "AGXDeviceUserClient" "IOSurfaceRootUserClient"))
  ```

  Test this on every GPU generation you use, since the names can differ.

### Extend `./loop doctor`

Doctor does not check any of the gaps above, or that the server is refused your home folder and the network. Each fix should
add an `expect_refused` line to `cmd_doctor`, so that a later macOS update cannot undo it unnoticed.

## Limit the damage

Seatbelt does not limit CPU, memory, processes or disk, and nothing in the sandbox protects the workspace from the agent.

- **Keep backups.** Use Time Machine, and commit often.
- **Limit disk use.** Put the workspace on its own disk image, so the agent cannot fill your main disk:

  ```sh
  hdiutil create -size 50g -type SPARSE -fs APFS -volname loop-work ~/loop-work
  hdiutil attach -nobrowse ~/loop-work.sparseimage
  ```

  Then set `WORKSPACE_DIR=/Volumes/loop-work`.
- **Limit CPU, memory and processes** with a [virtual machine](#stronger-boundaries). macOS has no equivalent of Linux's
  control groups, and `ulimit -u` counts all of your user's processes, not only the agent's.
- **Add confirmations to pi, as a convenience.** pi ships example extensions in its install, under
  `examples/extensions/`: `permission-gate.ts` and `confirm-destructive.ts`. They help prevent accidents, but they are not a
  security boundary. They match command text, which is easy to get around, and the agent can edit the extensions in its home.

## Control the network

Seatbelt's rules appear to tell only loopback from everything else, plus the port, so `LOOP_AGENT_NETWORK=open` includes
your local network and any VPN you are connected to, as well as the internet. To check, add a rule with a real address to
the profile, such as `(allow network-outbound (remote ip "10.0.0.1:443"))`, and see if `sandbox-exec` rejects it.

A proxy can make the finer choices instead. The agent gets one loopback port, a filtering proxy listens there outside the
sandbox, and the proxy decides where traffic may go. Direct connections stay refused, so the proxy cannot be bypassed.

| To allow | Proxy rule |
|---|---|
| Named hosts only | An allow list, for example `registry.npmjs.org` and `github.com` |
| The local network or VPN only | Destinations in your private ranges, such as `10.0.0.0/8` or Tailscale's `100.64.0.0/10` |
| The internet, but not the local network or VPN | Everything except private ranges, including `127.0.0.0/8` and `169.254.0.0/16` |

Filter on the address the proxy connects to, not only on the name, as a public name can point to a private address.

1. Run a proxy such as Squid on `127.0.0.1:3128`, with the rules you chose.
2. Set `LOOP_PORTS=8080,3128`, with `LOOP_AGENT_NETWORK=server`.
3. Add `HTTPS_PROXY` and `HTTP_PROXY` to the list of variables in `agent_run`, as they do not reach the sandbox today.
4. [Close the DNS gap](#dns-can-carry-data-out), or data can still leave through name lookups.

npm, pip, git and curl honor these variables, for HTTP and HTTPS. Other programs may not, and those simply fail to connect.
That includes SSH and database clients, so for those, use [a VM](#stronger-boundaries) with a firewall on its own network.

An allow list limits where data can go, but not what is sent there. An agent allowed to reach `github.com` could still post
your workspace to a public gist. To keep it out, allow only the registries you need, and give it no credentials.

A per-app firewall, such as LuLu or Little Snitch, is a useful second check on the sandbox's rules.

## Protect the supply chain

`./loop setup` runs outside the sandbox, so it matters what it downloads. The model is checksummed, and the runtime is
built from a pinned commit, but pi's dependencies are not.

- **Read the fork before you build it.** The runtime is a small, new fork with no releases, and its build runs its code
  on your Mac. The build runs in its own sandbox, with no network and no writes outside its folder, but it can still put
  whatever it likes into the server binary, which the server's sandbox then contains. Its two commits are on
  [GitHub](https://github.com/GuideboardLabs/llama.cpp-sensenova-loop/commits/sensenova-loop), as patches in
  `sensenova/patches/`. Moving to upstream llama.cpp once it supports the architecture would remove this risk.
- **The Metal patch is this repository's code,** in [`patches/`](../patches), applied to the fork before the build. It
  only adds kernels, their dispatch, and test cases. Read it as you would the fork's commits.
- **Lock pi's dependencies.** Commit a `package-lock.json`, and install it with `npm ci --ignore-scripts`, so a new release of
  a dependency cannot arrive unnoticed.
- **Move off the deprecated package.** npm marks `@mariozechner/pi-coding-agent` as deprecated, in favor of
  `@earendil-works/pi-coding-agent`. A deprecated package may stop getting security fixes.
- **Download only from pinned revisions.** Do not point `LOOP_MODEL_DIR` at model files of unknown origin. The server
  parses them, and its sandbox is what contains a flaw in that parser.

## Stronger boundaries

`sandbox-exec` shares the Mac's kernel and system services, and Apple has deprecated it. The next layers are independent of
it, so a flaw in one does not defeat the other.

**Only the server needs the GPU.** The agent does not, so it can move to a stronger boundary at no cost in speed, while the
server stays native and sandboxed.

| Layer | What it adds | Cost |
|---|---|---|
| A separate macOS user | File permissions as a second barrier, and process limits of its own | `agent_run` has to change. Your own files must not be readable by others |
| A container (Docker, or Apple's `container`) | A separate Linux kernel. No access to your files unless you mount them | Requires a container tool. Tools inside run Linux |
| A virtual machine (Lima, Tart or UTM) | A separate kernel, with limits on CPU, memory and disk | Most setup and memory. Sync the project in and out |
| A separate Mac for the agent | Physical separation | A second Mac |

**A separate user** needs a check of your own files first. A macOS home folder is usually readable by other users, including
files such as `~/.zshrc`. Run `chmod 700 ~`, and check that the agent's user is not an administrator.

**With a container or VM,** keep the server on loopback, and bring its port into the guest with a tunnel. Detection then finds
it at `127.0.0.1:8080` as usual:

```sh
ssh -R 8080:127.0.0.1:8080 agent-vm
```

`loop-detect` and the thinking extension should work there, with bash, curl, jq and node installed, but this repository does
not set this up, and it has not been tested. Mount only the project, and do not forward your SSH agent into the guest, as
that would hand it your keys.

The rules for [the workspace](#separate-your-projects) still apply: a stronger boundary does not help if you then run what
the agent wrote on your Mac without reading it.

## Which to choose

| You are running | Use |
|---|---|
| Your own code, with a model you are trying out | [Start here](#start-here), and keep backups |
| Other people's repositories | Also a [copy of the repository](#separate-your-projects), a fresh agent home, and the [profile fixes](#close-the-gaps-in-the-profiles) |
| Work where the agent needs the network | Also [the proxy](#control-the-network) |
| Anything you would not run on your Mac yourself | The agent in a [VM or container](#stronger-boundaries) |

If you close one of these gaps, or find that one is not real on your Mac, contributions are welcome. Report a way out of a
sandbox privately, as described in [Sandbox](sandbox.md#reporting-a-problem).
