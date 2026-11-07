// loop-thinking.ts on payloads that a one-prompt pi run does not produce: replayed tool calls and reasoning.
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const { default: extension } = await import(pathToFileURL(process.argv[2]).href);

let hook;
let level = "high";
extension({ on: (_, fn) => (hook = fn), getThinkingLevel: () => level });
const loop = { model: { provider: "loop-8080", id: "sensenova-loop-9b-q4-k-m" } };

const messages = [
	{ role: "system", content: "s" },
	{
		role: "assistant",
		content: "",
		reasoning_content: "long thought",
		tool_calls: [
			{ id: "1", function: { name: "a", arguments: "" } },
			{ id: "2", function: { name: "b", arguments: '{"x":1}' } },
		],
	},
	{ role: "tool", tool_call_id: "1", content: "r" },
];
const on = { messages, max_tokens: 24576, chat_template_kwargs: { enable_thinking: true } };

const out = hook({ payload: on }, loop);
assert.equal(out.messages[1].reasoning_content, undefined, "reasoning is not sent back");
assert.equal(out.messages[1].tool_calls[0].function.arguments, "{}", "empty arguments become {}");
assert.equal(out.messages[1].tool_calls[1].function.arguments, '{"x":1}', "other arguments are kept");
assert.deepEqual(out.messages[2], messages[2], "other messages are kept");
assert.deepEqual(out.chat_template_kwargs, { enable_thinking: true });
assert.equal(out.reasoning_effort, undefined, "the template has no efforts");
assert.equal(out.thinking_budget_tokens, 8192);

level = "xhigh";
assert.equal(hook({ payload: on }, loop).thinking_budget_tokens, 16384);
level = "low";
assert.equal(hook({ payload: { ...on, max_tokens: 4096 } }, loop).thinking_budget_tokens, 512, "never below 512");

// Thinking off: enable_thinking false, and the client's sampling as it was
const off = hook({ payload: { messages, temperature: 0.2 } }, loop);
assert.deepEqual(off.chat_template_kwargs, { enable_thinking: false });
assert.equal(off.temperature, 0.2);
assert.equal(off.presence_penalty, undefined);
assert.equal(off.thinking_budget_tokens, undefined);

assert.equal(hook({ payload: on }, { model: { provider: "openai", id: "x" } }), undefined, "other providers are left alone");
