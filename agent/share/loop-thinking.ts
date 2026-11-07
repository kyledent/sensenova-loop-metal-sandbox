// pi requests for SenseNova Loop 9B Preview. loop-detect installs this file as ~/.pi/agent/extensions/loop-thinking.ts.
//
// pi's qwen-chat-template format sends only chat_template_kwargs.enable_thinking, so every level would think the same
// way. The model's chat template has no reasoning effort, so this adds the one thing that tells the levels apart:
// llama.cpp's thinking_budget_tokens, as a top-level field (a budget inside chat_template_kwargs is ignored), to each
// request to a loop* provider. The thinking counts in max_tokens, so the budget is cut to leave room for the answer.
// Thinking off is chat_template_kwargs.enable_thinking=false, with the client's sampling left as it is: the model card
// gives none for that mode.
//
// For agent loops: empty tool arguments become "{}", which a template's arguments filter cannot read, and earlier
// reasoning is not sent back, so that each request starts with the same text as the last and the prompt cache holds.
//
// LOOP_THINKING_LEVELS overrides the budgets: "low=2048,medium=4096,high=8192,xhigh=16384" (a budget of 0 means all of
// max_tokens but the room for the answer). Compaction summaries do not pass through this hook; they get the server's
// --reasoning-budget, and pi sends them the conversation as text.
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const DEFAULTS: Record<string, number> = { low: 2048, medium: 4096, high: 8192, xhigh: 16384 };
const ANSWER_ROOM = 4096; // tokens kept for the answer after the thinking

function budgets(): Record<string, number> {
	const out = { ...DEFAULTS };
	for (const item of (process.env.LOOP_THINKING_LEVELS ?? "").split(",")) {
		const m = item.trim().match(/^(\w+)=(\d+)$/);
		if (m) out[m[1]] = Number(m[2]);
	}
	return out;
}

function cleanMessage(message: Record<string, any>): Record<string, any> {
	if (message.role !== "assistant") return message;
	const { reasoning_content, reasoning, ...rest } = message;
	if (rest.tool_calls) {
		rest.tool_calls = rest.tool_calls.map((call: Record<string, any>) =>
			call.function && !String(call.function.arguments ?? "").trim()
				? { ...call, function: { ...call.function, arguments: "{}" } }
				: call,
		);
	}
	return rest;
}

export default function (pi: ExtensionAPI) {
	const table = budgets();
	pi.on("before_provider_request", (event, ctx) => {
		const p = event.payload as Record<string, any> | undefined;
		if (!p || !ctx.model?.provider.startsWith("loop")) return;
		const out = { ...p, messages: (p.messages ?? []).map(cleanMessage) };
		if (p.chat_template_kwargs?.enable_thinking !== true) {
			return { ...out, chat_template_kwargs: { ...p.chat_template_kwargs, enable_thinking: false } };
		}
		const level = table[pi.getThinkingLevel()];
		if (level === undefined) return out;
		const maxNew = Number(p.max_completion_tokens ?? p.max_tokens ?? 0);
		let budget = level;
		if (maxNew > 0) budget = budget > 0 ? Math.min(budget, maxNew - ANSWER_ROOM) : maxNew - ANSWER_ROOM;
		return { ...out, thinking_budget_tokens: Math.max(512, budget) };
	});
}
