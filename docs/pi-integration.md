# pi integration

Every time pi starts, `loop-detect` finds the running SenseNova Loop servers and writes pi's configuration, so there is
nothing to set by hand. **pi's auto-compaction and thinking levels both work with this model**, and the defaults depend
on the size of the context.

All of this applies to pi 0.73.1, the pinned version. pi's files are in the agent's own home, at
`.state/home/.pi/agent/`.

## Model detection

`loop-detect` asks each port in `LOOP_PORTS` for `/health`, `/props` and `/v1/models`. A server counts when its model id
contains `sensenova-loop`, so a second server you started yourself shows up, and another model on the same port does not.

Each one becomes a provider `loop-<port>` in `models.json`, with the model id and context that the server reports:

```json
{
  "providers": {
    "loop-8080": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "LOOP_API_KEY",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "thinkingFormat": "qwen-chat-template"
      },
      "models": [{
        "id": "sensenova-loop-9b-q4-k-m",
        "name": "sensenova-loop-9b-q4-k-m (:8080, 32768 ctx)",
        "reasoning": true,
        "input": ["text"],
        "contextWindow": 32768,
        "maxTokens": 8192,
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "thinkingLevelMap": {"minimal": null, "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh"}
      }]
    }
  }
}
```

`apiKey` names an environment variable, which pi reads, so the key itself is not written to the file.

Providers whose names start with `loop` belong to the script, and each run replaces them. Your other providers are kept.
If you start a server while pi is open, run `./loop detect` in a second terminal, then open `/model`.

## Thinking levels

Change the level with Shift+Tab, or start with `--thinking <level>`. The default is `high`, set by
`defaultThinkingLevel` in `settings.json`.

| pi level | Thinking budget (tokens) |
|---|---|
| `off` | none: `enable_thinking` is false |
| `minimal` | hidden: it would be the same as `low` |
| `low` | 2,048 |
| `medium` | 4,096 |
| `high` (default) | 8,192 |
| `xhigh` | 16,384 |

The model's chat template turns thinking on or off, and has no reasoning effort. pi on its own sends only
`chat_template_kwargs.enable_thinking`, so all its levels would think alike. The `loop-thinking` extension adds the
level's budget to each request, as llama.cpp's top-level `thinking_budget_tokens`, since the server ignores a budget
inside `chat_template_kwargs`. `loop-detect` installs it in `extensions/`.

With thinking off, the extension leaves the sampling as pi sends it: the model card gives no settings for that mode.

- **To change the table**, set `LOOP_THINKING_LEVELS`, for example `high=6000`. pi's `thinkingBudgets` setting has no
  effect here.
- **To turn thinking off altogether**, set `LOOP_THINKING=0`.
- **Time:** thinking at 8K tokens takes minutes on a Mac, and it stays in the context until compaction. `./loop bench`
  shows how fast yours writes.

The output limit caps the budgets: the thinking counts in it, and 4,096 tokens are kept for the answer. See the table
below.

## Auto-compaction

pi summarizes older messages when `context tokens > context window - reserveTokens`. It checks this when an agent run
ends, so one run of tool calls has to fit in the reserve. If a run does overflow, pi recognizes llama.cpp's "exceeds the
available context size" error, compacts, and retries once. `/compact` does it by hand.

`loop-detect` writes these values, sized from the smallest context found, but only where you have not set a value:

| Context (by RAM) | Max output | Budget cap per level | `reserveTokens` | `keepRecentTokens` | Summary max output | Server budget |
|---|---|---|---|---|---|---|
| 8K (up to 11 GB) | 2,048 | 512 | 2,048 | 1,638 | 1,638 | 512 |
| 16K (up to 23 GB) | 4,096 | 512 | 4,096 | 3,276 | 3,276 | 1,024 |
| 32K (up to 35 GB) | 8,192 | 4,096 | 8,192 | 6,553 | 6,553 | 2,048 |
| 64K (up to 71 GB) | 16,384 | 12,288 | 16,384 | 13,107 | 13,107 | 4,096 |
| 128K (more) | 24,576 | 20,480 | 24,576 | 20,000 | 19,660 | 8,192 |

Below 64K the levels start to merge, and on 16K or less they are all the same. If you can spare the memory, use a larger
context: `./loop use 64K`.

Summary requests come from pi directly and skip the extension, so they use the server's `--reasoning-budget`. That is why
the server's budget is only a sixteenth of the context: a larger one could use up a summary's whole output on thinking.
Set it with `LOOP_REASONING_BUDGET`.

To change compaction, edit `settings.json`. The values are written once, so after a big change to the context, edit or
delete them and run `./loop detect`:

```json
{
  "compaction": {"enabled": true, "reserveTokens": 16384, "keepRecentTokens": 13107}
}
```

Each compaction has a cost: the server reads the summarized conversation again as a new prompt.

## Other defaults

`loop-detect` also sets these, again only where you have not set a value:

- `retry.provider.timeoutMs`: 1 hour, as a long prompt read takes minutes.
- `retry.provider.maxRetries`: 0, and `retry.maxRetries`: 1. The server has one slot, so a retry would wait behind the
  request it is still reading.
- `defaultProvider` and `defaultModel`: the first server found, if none is set, the default server is gone, or it now
  serves another quant.

For agent loops, the extension also turns empty tool arguments into `{}`, which a chat template cannot read otherwise, and
does not send earlier reasoning back, so that each request starts with the same text as the last and the prompt cache
holds.

## What has been tested

`tests/run.sh` runs the real pi 0.73.1 against a mock server, and checks the requests it sends:

- `off`, `low`, `medium`, `high` and `xhigh`: the budget in each request, and no effort.
- Auto-compaction: a summary request follows when the server reports a full context, with the expected output limit.

The real model has not been part of these tests, so the mock cannot show how well it thinks or summarizes. On your Mac,
`./loop check` tests the real server: the thinking budget, the overflow error that pi's retry depends on, and a summary
request like pi's. See [Checks and benchmarks](checks.md).
