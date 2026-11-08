#!/bin/bash
# Tests of everything but the Seatbelt rules themselves, on any machine with bash, curl, jq, node and python:
# ./loop, loop-detect and the extension, with a mock llama-server and the real pi. sandbox-exec, the build tools and
# the other macOS tools are stubs here, so the sandboxes and the build are checked only by ./loop on a Mac.
#
#   tests/run.sh PI_CLI     PI_CLI: dist/cli.js of an installed @mariozechner/pi-coding-agent
set -uo pipefail

PI_CLI=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PYTHON=$(command -v python3 2>/dev/null) && "$PYTHON" -c '' 2>/dev/null || PYTHON=$(command -v python)
PORT=18080
OTHER_PORT=18081
WORK=$(mktemp -d)
FAILS=0
OTHER_PID=
COMMIT=fad174ecd8bf22746a626c58e67e193f095aaa46

cleanup() {
    (cd "$WORK/repo" 2>/dev/null && ./loop down >/dev/null 2>&1)
    [ -z "$OTHER_PID" ] || kill "$OTHER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # label, then a command that must succeed
    local label=$1; shift
    if "$@"; then echo "ok    $label"; else echo "FAIL  $label"; FAILS=$((FAILS + 1)); fi
}

# --- Static checks
for f in loop agent/bin/loop-detect agent/bin/pi tests/run.sh; do
    check "bash -n $f" bash -n "$SRC/$f"
done
balanced() { "$PYTHON" -I -c '
import re, sys
text = re.sub(r"#\"[^\"]*\"|\"[^\"]*\"|;.*", "", open(sys.argv[1]).read())
depth = 0
for c in text:
    depth += (c == "(") - (c == ")")
    if depth < 0: sys.exit(1)
sys.exit(depth != 0)' "$1"; }
for f in sandbox/server.sb sandbox/agent.sb sandbox/build.sb; do check "balanced parens $f" balanced "$SRC/$f"; done
if command -v "${CXX:-c++}" >/dev/null 2>&1; then
    check "the Metal patch's kernels, run on the CPU, match the fork's CPU code" sh -c \
        '"$0/tests/metal-kernels.sh" "$1" >/dev/null' "$SRC" "${CXX:-c++}"
else
    echo "skip  the Metal patch's kernels: no C++ compiler (set CXX)"
fi

# --- A copy of the repo, with stubs for what only a Mac has, and for what setup would download
mkdir -p "$WORK/stubs" "$WORK/repo"
cp -R "$SRC/loop" "$SRC/agent" "$SRC/sandbox" "$SRC/patches" "$SRC/.env.example" "$WORK/repo/"
cd "$WORK/repo" || exit 1
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$WORK/stubs/$1"; chmod +x "$WORK/stubs/$1"; }
stub uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac'
echo 34359738368 > "$WORK/memsize"
stub sysctl "case \"\$2\" in hw.memsize) cat '$WORK/memsize' ;; hw.ncpu) echo 8 ;; *) echo test ;; esac"
stub getconf "echo '$WORK'"
# Record the profile and its parameters, then run the program
stub sandbox-exec "
log='$WORK/sandbox.log'
while [ \$# -gt 0 ]; do
    case \"\$1\" in
        -f) echo \"profile \$2\" >> \"\$log\"; shift 2 ;;
        -D) echo \"param \$2\" >> \"\$log\"; shift 2 ;;
        *) break ;;
    esac
done
echo \"exec \$*\" >> \"\$log\"
echo \"cwd \$(pwd -P)\" >> \"\$log\"
exec \"\$@\""
# The build has a folder of its own for the commit and the version of the Metal patch
RUNTIME_ID=${COMMIT:0:12}-metal-$(shasum -a 256 "$SRC/patches/0001-metal-mhc-route-and-merge.patch" | cut -c 1-8)
LLAMA_DIR=.runtime/llama/$RUNTIME_ID
stub ps "kill -0 \"\$2\" 2>/dev/null || exit 1; echo '$(pwd -P)/$LLAMA_DIR/llama-server'"
# The agent's PATH holds jq's folder, so these two reach it wherever this machine keeps them (jq.exe: without its CRs)
stub curl "exec '$(command -v curl)' \"\$@\""
stub jq "set -o pipefail; '$(command -v jq)' \"\$@\" | tr -d '\\r'"
export PATH="$WORK/stubs:$PATH"

# The mock server, as the build would leave it. While fail-q3 exists, a Q3_K_M server fails to load.
printf '#!/bin/bash\ncase "$*" in *Q3_K_M*) [ ! -f "%s" ] || exit 1 ;; esac\nexec "%s" -I "%s" --record "%s" --usage-file "%s" "$@"\n' \
    "$WORK/fail-q3" "$PYTHON" "$SRC/tests/mock_llama.py" "$WORK/requests.jsonl" "$WORK/usage" > "$WORK/llama-server.mock"
chmod +x "$WORK/llama-server.mock"
mkdir -p models .runtime/pi/bin
# Node on Windows ignores HOME; on macOS pi finds this folder by itself
printf '#!/bin/bash\nexport PI_CODING_AGENT_DIR="$HOME/.pi/agent"\nexec node "%s" "$@"\n' "$PI_CLI" > .runtime/pi/bin/pi
chmod +x .runtime/pi/bin/pi
echo 0.73.1 > .runtime/pi/.version
: > models/SenseNova-Loop-9B-Preview-Q4_K_M.gguf

export LOOP_PORTS="$PORT-$OTHER_PORT"
WORKSPACE_FILE=workspace/big.txt
mkdir -p workspace
contains() { grep -q -- "$2" "$1"; }

# --- Setup builds the fork: git and cmake are stubs that record what they are asked, and wc passes the empty model
stub xcrun 'exit 0'
stub git "echo \"git \$*\" >> '$WORK/git.log'
case \"\$*\" in
    *rev-parse*) if [ -f '$WORK/wrong-commit' ]; then echo 0123456789abcdef; else echo $COMMIT; fi ;;
    'init -q '*) mkdir -p \"\$3/.git\" ;;
esac"
stub cmake "echo \"cmake \$*\" >> '$WORK/cmake.log'
case \"\$*\" in *--build*) mkdir -p build/bin && cp '$WORK/llama-server.mock' build/bin/llama-server && printf '#!/bin/bash\n' > build/bin/test-backend-ops && chmod +x build/bin/test-backend-ops ;; esac"
stub wc 'echo 5628723360'
: > "$WORK/wrong-commit"
check "setup refuses a checkout that is not the pinned commit" sh -c '! ./loop setup >/dev/null 2>&1'
rm -f "$WORK/wrong-commit"
check "./loop setup builds llama.cpp" sh -c './loop setup >/dev/null'
check "build: fetches the pinned commit of the fork" contains "$WORK/git.log" \
    "fetch -q --depth 1 https://github.com/GuideboardLabs/llama.cpp-sensenova-loop.git $COMMIT"
check "build: static, with Metal, and without the web UI's download" contains "$WORK/cmake.log" \
    "-DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON .*-DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF"
check "build: applies the Metal patch, after checking that it applies" sh -c \
    "grep -q 'apply --check .*/patches/0001-metal-mhc-route-and-merge.patch' '$WORK/git.log' && grep -q 'apply .*/patches/0001-metal-mhc-route-and-merge.patch\$' '$WORK/git.log'"
check "build: the server, and the test that compares the kernels with the CPU's" sh -c \
    "grep -q -- '-DLLAMA_BUILD_TESTS=ON ' '$WORK/cmake.log' && grep -q -- '--build build --target llama-server test-backend-ops -j 8' '$WORK/cmake.log'"
check "build: in its sandbox" contains "$WORK/sandbox.log" 'profile .*sandbox/build.sb'
check "build: the sandbox may write the source folder" contains "$WORK/sandbox.log" 'param SRC=.*/.runtime/llama-src'
check "build: the server and the test are installed" sh -c "test -x '$LLAMA_DIR/llama-server' && test -x '$LLAMA_DIR/test-backend-ops'"
: > "$WORK/cmake.log"
check "setup does not build again" sh -c "./loop setup >/dev/null && ! grep -q . '$WORK/cmake.log'"
: > "$WORK/git.log"
check "LOOP_METAL_PORT=0 builds without the patch" sh -c "LOOP_METAL_PORT=0 ./loop setup >/dev/null && ! grep -q apply '$WORK/git.log'"
check "without the patch: the server only, and a folder of its own" sh -c \
    "grep -q -- '-DLLAMA_BUILD_TESTS=OFF ' '$WORK/cmake.log' && grep -q -- '--target llama-server -j 8' '$WORK/cmake.log' && test -x .runtime/llama/${COMMIT:0:12}/llama-server"
rm -f "$WORK/stubs/git" "$WORK/stubs/cmake" "$WORK/stubs/xcrun" "$WORK/stubs/wc"

# --- Server start and flags
: > "$WORK/sandbox.log"
check "./loop up starts the server" ./loop up
check "server runs under its profile" contains "$WORK/sandbox.log" 'profile .*sandbox/server.sb'
check "server gets its port as a parameter" contains "$WORK/sandbox.log" "param PORT=$PORT"
check "server starts in its own folder, not this repository" contains "$WORK/sandbox.log" "^cwd .*/.runtime/llama/"
# 32 GB: Q4_K_M, the 32K tier, a 2K budget for requests without one, and an 8 GiB prompt cache
check "server command has the flags" contains "$WORK/sandbox.log" \
    "exec .*llama-server -m .*SenseNova-Loop-9B-Preview-Q4_K_M.gguf --host 127.0.0.1 --port $PORT --alias sensenova-loop-9b-q4-k-m -ngl 99 -fa on -c 32768 --temp 1.0 --top-p 0.95 --top-k 50 --min-p 0 --jinja --reasoning-format deepseek --reasoning-budget 2048 --parallel 1 --cache-ram 8192 --no-webui"
check "./loop status reports it" sh -c './loop status | grep -q "ready: sensenova-loop-9b-q4-k-m"'
check "a key is generated and kept out of the agent's reach" test -s .state/api-key
http_code() { curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' -d '{}' "$@"; }
check "the server refuses requests without the key" test "$(http_code "http://127.0.0.1:$PORT/v1/chat/completions")" = 401

# --- Detection, in the agent's sandbox wrapper
"$PYTHON" -I "$SRC/tests/mock_llama.py" --port "$OTHER_PORT" --alias qwen-other &
OTHER_PID=$!
sleep 1
AH=.state/home/.pi/agent
mkdir -p "$AH"
echo '{"providers": {"mine": {"baseUrl": "http://x"}, "loop-9": {"baseUrl": "http://stale"}}}' > "$AH/models.json"
check "./loop detect runs" ./loop detect
query() { jq -e "$2" "$AH/$1" >/dev/null; }
check "provider written with the server's id and ctx" query models.json \
    ".providers[\"loop-$PORT\"].models[0] | .id == \"sensenova-loop-9b-q4-k-m\" and .contextWindow == 32768 and .maxTokens == 8192"
check "other llama-server is left out" query models.json ".providers | has(\"loop-$OTHER_PORT\") | not"
check "stale loop provider is replaced" query models.json '.providers | has("loop-9") | not'
check "other provider is kept" query models.json '.providers | has("mine")'
check "text only" query models.json ".providers[\"loop-$PORT\"].models[0].input == [\"text\"]"
check "every level but minimal is offered" query models.json \
    ".providers[\"loop-$PORT\"].models[0].thinkingLevelMap == {minimal: null, low: \"low\", medium: \"medium\", high: \"high\", xhigh: \"xhigh\"}"
check "default model set" query settings.json ".defaultProvider == \"loop-$PORT\" and .defaultModel == \"sensenova-loop-9b-q4-k-m\""
check "compaction sized from the context" query settings.json '.compaction.reserveTokens == 8192 and .compaction.keepRecentTokens == 6553'
check "extension installed" test -f "$AH/extensions/loop-thinking.ts"
check "agent runs under its profile" contains "$WORK/sandbox.log" 'profile .*\.state/agent.sb'
check "agent's generated profile allows the server ports only" sh -c \
    "grep -q 'remote ip \"localhost:$PORT\"' .state/agent.sb && ! grep -q 'localhost:\*' .state/agent.sb"

# The calling shell's secrets stay out of the sandbox, and LOOP_ settings go in
printf '#!/bin/bash\nenv > "%s"\n' "$WORK/agent.env" > agent/bin/loop-detect.real
mv agent/bin/loop-detect agent/bin/loop-detect.saved
mv agent/bin/loop-detect.real agent/bin/loop-detect
SECRET_TOKEN=x LOOP_THINKING_LEVELS=low=1 ./loop detect
mv agent/bin/loop-detect.saved agent/bin/loop-detect
check "a secret of the calling shell stays out" sh -c "! grep -q SECRET_TOKEN '$WORK/agent.env'"
check "LOOP_ settings go in" contains "$WORK/agent.env" LOOP_THINKING_LEVELS=low=1
check "HOME is the agent's own" contains "$WORK/agent.env" 'HOME=.*\.state/home'

# --- The real pi with the extension: what does a request look like?
last_request() { tail -n 1 "$WORK/requests.jsonl"; }
ask() {
    rm -f "$WORK/requests.jsonl"
    ./loop pi --no-session -p "ping" "$@" > "$WORK/pi.out" 2>&1 && return 0
    sed "s/^/      pi: /" "$WORK/pi.out"; return 1
}

check "pi answers through the mock server" ask
check "pi printed the answer" contains "$WORK/pi.out" pong
req() { last_request | jq -e "$1" >/dev/null; }
# 32K context: max output 8K (a quarter), so the 8K budget is cut to leave 4K for the answer
check "default level: high, budget cut to fit, no effort" req '(has("reasoning_effort") | not) and .thinking_budget_tokens == 4096 and .max_tokens // .max_completion_tokens == 8192 and .chat_template_kwargs.enable_thinking == true'
check "one leading system message" req '[.messages[] | select(.role == "system" or .role == "developer")] | length == 1 and .[0].role == "system"'
check "system message comes first" req '.messages[0].role == "system"'

check "pi --thinking medium" ask --thinking medium
check "medium: a 4K budget" req '.thinking_budget_tokens == 4096'
check "pi --thinking low" ask --thinking low
check "low: a 2K budget" req '.thinking_budget_tokens == 2048 and (has("reasoning_effort") | not)'
check "pi --thinking off" ask --thinking off
check "off: no thinking, no budget, pi's own sampling" req '.chat_template_kwargs.enable_thinking == false and (has("thinking_budget_tokens") | not) and (has("presence_penalty") | not) and (has("reasoning_effort") | not)'

check "extension workarounds" node --experimental-strip-types --no-warnings "$SRC/tests/extension.mjs" "$SRC/agent/share/loop-thinking.ts"

check "pi --thinking xhigh" ask --thinking xhigh
check "xhigh: budget cut to fit" req '.thinking_budget_tokens == 4096'

# --- Auto-compaction: pi, with the settings from detection, summarizes once the server reports a full context
"$PYTHON" -I -c 'print("filler text " * 4000)' > "$WORKSPACE_FILE"
echo 30000 > "$WORK/usage"
rm -f "$WORK/requests.jsonl"
compact_run() {
    ./loop pi --no-session -p @big.txt first second third > "$WORK/pi.out" 2>&1 && return 0
    sed "s/^/      pi: /" "$WORK/pi.out"; return 1
}
check "pi runs with a full context" compact_run
rm -f "$WORK/usage"
summary() { jq -e 'select(.messages[0].content | tostring | test("summar"; "i"))' "$WORK/requests.jsonl" > "$WORK/summary.json"; }
check "auto-compaction sent a summary request" summary
check "summary: 80% of the reserve as max output" jq -es '.[0] | (.max_tokens // .max_completion_tokens) == 6553' "$WORK/summary.json"
check "summary: uses the server's budget, not the extension's" jq -es 'length > 0 and (.[0] | has("thinking_budget_tokens") | not)' "$WORK/summary.json"

# --- Quants and contexts
: > models/SenseNova-Loop-9B-Preview-Q4_0.gguf
models_list() { local out; out=$(./loop models); echo "$out" | grep -q 'Q4_0 .*SenseNova-Loop-9B-Preview-Q4_0.gguf (downloaded)'; }
check "./loop models lists the quants" models_list
check "./loop models marks the selected and running one" sh -c './loop models | grep -q "Q4_K_M .*(downloaded, selected, running)"'
check "./loop models: a quant not downloaded" sh -c './loop models | grep -q "Q3_K_M .*(not downloaded)"'
check "an unknown quant is refused" sh -c '! LOOP_QUANT=Q2_K ./loop status 2>/dev/null'
check "asking for another quant does not replace a running server" sh -c '! LOOP_QUANT=Q4_0 ./loop up 2>/dev/null'
echo 8589934592 > "$WORK/memsize"
check "8 GB: Q3_K_M by default" sh -c './loop models | grep -q "Q3_K_M .*selected"'
echo 137438953472 > "$WORK/memsize"
: > "$WORK/sandbox.log"
check "restart on 128 GB" ./loop restart
check "128 GB: the top tier" contains "$WORK/sandbox.log" 'exec .* -c 131072 '

# --- Serving checks and benchmarks, against the mock's timings and errors (a 128K context here)
check "./loop check passes" sh -c './loop check > "$0/check.out"' "$WORK"
check "check: all six ran" sh -c 'test "$(grep -c "^  ok " "$0/check.out")" -eq 6' "$WORK"
check "check: the budget is kept" contains "$WORK/check.out" "ok    thinking stays within its budget  (256 of 256 tokens)"
check "check: the summary's limit is 80% of the reserve" contains "$WORK/check.out" "limit 19660"
check "check: thinking off is asked for, with no sampling of its own" sh -c \
    "grep 'single word' '$WORK/requests.jsonl' | head -n 1 | jq -e '.chat_template_kwargs.enable_thinking == false and (has(\"temperature\") | not)' >/dev/null"
check "./loop bench measures each size" sh -c './loop bench 512 2048 > "$0/bench.out"' "$WORK"
check "bench: a row per size" sh -c 'test "$(grep -cE "^  [0-9]+ +500 tokens/s +[0-9.]+ s +20 tokens/s \(128 tokens\)" "$0/bench.out")" -eq 2' "$WORK"
check "bench: results kept, with the model, the runtime and speeds" sh -c \
    "jq -es 'length == 2 and all(.model == \"sensenova-loop-9b-q4-k-m\" and .runtime == \"$RUNTIME_ID\" and .prefill_tps == 500 and .generation_tps == 20 and .generated_tokens == 128)' .state/bench.jsonl >/dev/null"
check "bench refuses a size that is not a number" sh -c '! ./loop bench lots 2>/dev/null'
LOOP_SERVER_ARGS="--overflow-text=context-too-long --think-tokens=30000" ./loop restart >/dev/null
check "check fails when pi would miss an overflow, or a summary is cut off" sh -c '! ./loop check > "$0/check.out"' "$WORK"
check "check: names the overflow" contains "$WORK/check.out" "FAIL  an overflow is reported in the words pi recognizes"
check "check: names the cut-off summary" contains "$WORK/check.out" "FAIL  a compaction summary fits its output limit  (cut off"
./loop restart >/dev/null

# --- Switching with ./loop use: .env and the server together, and the old server back if the new one fails
: > "$WORK/sandbox.log"
check "./loop use Q4_0 switches the server" sh -c './loop use Q4_0 >/dev/null'
check "use: .env keeps the quant" contains .env '^LOOP_QUANT=Q4_0$'
check "use: the Q4_0 is served" sh -c './loop status | grep -q "ready: sensenova-loop-9b-q4-0"'
check "use: its file" contains "$WORK/sandbox.log" 'exec .*SenseNova-Loop-9B-Preview-Q4_0.gguf .*--alias sensenova-loop-9b-q4-0 '
check "use: ./loop up keeps it" sh -c './loop up | grep -q "^Server already running on port"'
: > "$WORK/sandbox.log"
check "./loop use 32k changes only the context" sh -c './loop use 32k >/dev/null'
check "use: .env keeps the context" contains .env '^LOOP_CTX=32768$'
check "use: served with it" contains "$WORK/sandbox.log" 'exec .*Q4_0.gguf .* -c 32768 '
check "use: the same setup again is not a restart" sh -c './loop use q4_0 32K | grep -q "^Already serving Q4_0"'
check "use refuses what it does not know" sh -c '! ./loop use Q8_0 2>/dev/null'
check "use refuses a context out of range" sh -c '! ./loop use 300K 2>/dev/null'
: > models/SenseNova-Loop-9B-Preview-Q3_K_M.gguf
: > "$WORK/fail-q3"
check "use: a server that fails to start is reported" sh -c '! ./loop use q3_k_m >/dev/null 2>&1'
check "use: .env is as it was" sh -c "grep -q '^LOOP_QUANT=Q4_0' .env && grep -q '^LOOP_CTX=32768' .env"
check "use: the previous server is back" sh -c './loop status | grep -q "ready: sensenova-loop-9b-q4-0, ctx 32768"'
rm -f "$WORK/fail-q3"
check "use: a shell setting that would override .env is named" sh -c \
    'LOOP_QUANT=Q4_0 ./loop use Q4_0 2>&1 >/dev/null | grep -q "your shell sets LOOP_QUANT"'
echo 8589934592 > "$WORK/memsize"
check "use warns when the setup will not fit" sh -c './loop use Q4_K_M 64K 2>&1 | grep -q "Warning: Q4_K_M with a 65536-token context"'
echo 137438953472 > "$WORK/memsize"
check "./loop use Q4_K_M auto goes back" sh -c './loop use Q4_K_M auto >/dev/null'
check "use: auto empties the context" contains .env '^LOOP_CTX=$'
check "use: the context by RAM again" sh -c './loop status | grep -q "ready: sensenova-loop-9b-q4-k-m, ctx 131072"'
: > "$WORK/sandbox.log"
check "./loop use cpu switches to the build without the Metal patch" sh -c './loop use cpu >/dev/null'
check "use: .env keeps it" contains .env '^LOOP_METAL_PORT=0$'
check "use: the server runs from that build" contains "$WORK/sandbox.log" "exec .*/.runtime/llama/${COMMIT:0:12}/llama-server "
check "use: ./loop models names the build" sh -c "./loop models | grep -q 'Build: ${COMMIT:0:12}, with the routing on the CPU'"
: > "$WORK/sandbox.log"
check "./loop use metal goes back" sh -c './loop use metal >/dev/null'
check "use: the server runs from the patched build" contains "$WORK/sandbox.log" "exec .*/$LLAMA_DIR/llama-server "
check "use: .env keeps that too" contains .env '^LOOP_METAL_PORT=1$'

# --- The context selector: the sizes with their memory, and a choice read from stdin
check "./loop ctx lists the sizes, with the current one" sh -c     './loop ctx </dev/null 2>/dev/null | grep -q "^  5)  128K  about .* GB   (current, default for this Mac)$"'
echo 8589934592 > "$WORK/memsize"
check "ctx: marks what does not fit" sh -c './loop ctx </dev/null 2>/dev/null | grep -q "^  4)   64K  about .*too big)$"'
echo 137438953472 > "$WORK/memsize"
check "ctx: a choice from the list is served and kept" sh -c     'echo 2 | ./loop ctx >/dev/null 2>&1 && grep -q "^LOOP_CTX=16384$" .env && ./loop status | grep -q "ready: sensenova-loop-9b-q4-k-m, ctx 16384"'
check "ctx: a size on the command line" sh -c './loop ctx 32k >/dev/null 2>&1 && grep -q "^LOOP_CTX=32768$" .env'
check "ctx: auto goes back" sh -c 'echo a | ./loop ctx >/dev/null 2>&1 && grep -q "^LOOP_CTX=$" .env && ./loop status | grep -q "ctx 131072"'
check "ctx: refuses a choice not in the list" sh -c '! echo 9 | ./loop ctx >/dev/null 2>&1'
check "ctx: refuses what is not a size" sh -c '! ./loop ctx big >/dev/null 2>&1'

# --- One of ours whose pid file is gone: found by its port
ORPHAN=$(cat .state/server.pid)
rm -f .state/server.pid .state/server.model
stub lsof "echo $ORPHAN"
check "a server without its pid file is found by its port" sh -c "./loop status | grep -q 'running, pid $ORPHAN'"
check "its quant is unknown, so another one is refused" sh -c '! LOOP_QUANT=Q4_0 ./loop up 2>/dev/null'

# --- Restart and stop
check "./loop down stops it" ./loop down
rm -f "$WORK/stubs/lsof"
check "./loop down twice is fine" ./loop down
check "no server answers after down" sh -c "! curl -fsS -m 2 http://127.0.0.1:$PORT/health >/dev/null 2>&1"
rm -f "$WORK/stubs/sandbox-exec"
check "refuses to run without sandbox-exec" sh -c '! ./loop status >/dev/null 2>&1'

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS failed"; exit 1; fi
echo "All passed."
