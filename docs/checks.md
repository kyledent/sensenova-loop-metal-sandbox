# Serving checks and benchmarks

`./loop doctor` tests the sandboxes. These two commands test the running server instead: whether it serves pi
correctly, and how fast. Both send requests the way pi does, from outside the sandboxes, with the server's API key.

The server has one slot, so their requests wait behind pi's. Run them while pi is idle.

## `./loop check`

```sh
./loop check
```

Each check prints `ok`, `FAIL` or `warn`, and the command exits with an error if any check failed. The last three read
long prompts, so on a 16 GB Mac the whole run can take several minutes.

| Check | What it sends | Why it matters | If it fails |
|---|---|---|---|
| It answers with thinking off | A short question, with thinking off as the extension sends it | `off` in pi | Look in `.state/server.log` |
| Thinking stays within its budget | A question with a 256-token budget | pi's thinking levels differ by budget alone, through llama.cpp's `thinking_budget_tokens` | The budget is not applied, so every level thinks as long as it likes. Report it, with the runtime's commit |
| A tool call is well formed | A request with one tool, `read_file` | pi works through tool calls | A warning, not a failure: the model is a preview. Try again, or try thinking on |
| It reads a prompt of 85% of the context | Text filling 85% of the context | A long session must fit in memory and be read | Usually memory: `./loop use 16K`, a smaller quant, or a lower `LOOP_CACHE_RAM` |
| An overflow is reported in the words pi recognizes | A prompt longer than the context | pi compacts and retries once when a request overflows, but only if the error matches its pattern for llama.cpp | pi will show the error instead of compacting. The runtime's wording has changed: report it |
| A compaction summary fits its output limit | A long conversation, then a request for a summary, as pi sends it | pi's summaries skip the extension, so they use the server's thinking budget, and thinking counts against the summary's output limit | Lower `LOOP_REASONING_BUDGET` |

For the summary, the check fills the context up to pi's reserve, as when compaction starts, and sets the output limit
pi would: 80% of the reserve. It reproduces pi's request, but it is not pi itself, so it cannot show how good the
summary is. The prefill check and the summary also report how fast the prompt was read.

Requests time out after 15 minutes each. Set `LOOP_CHECK_TIMEOUT`, in seconds, for a slower Mac.

## `./loop bench`

```sh
./loop bench                # prompts of 512, 2048 and 8192 tokens
./loop bench 1024 16384     # or the sizes you choose
```

For each prompt size it reports:

- **Prefill:** how fast the server reads the prompt, in tokens per second.
- **First token:** how long reading it took, which is the wait before an answer starts.
- **Generation:** how fast it writes, over 128 tokens, with thinking off.

Sizes that do not fit the context are skipped. A first, short request is not counted, as it also compiles Metal's
kernels. Prompts are new each time, so the prompt cache does not help, as in a fresh session.

Each result is added to `.state/bench.jsonl`, with the quant, the context, the runtime's commit, the Mac, its chip, its
memory and the macOS version, so you can compare runs, for example before and after a change of context or of runtime.
There are no published figures for this model on a Mac yet, so results are welcome. See [Metal](metal.md) for why
they matter.

Speed varies with what else the Mac is doing, its temperature and Low Power Mode. Close other heavy apps, and run it
twice if the numbers look off.
