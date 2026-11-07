#!/usr/bin/env python3
"""A stand-in for llama-server: the endpoints that ./loop, loop-detect and pi use. Records chat requests.

A token is a word here. Streamed chat answers pi; the rest answers ./loop check and bench, as the fork does: timings,
a thinking budget, tool calls, the prompt cache, and its error for a prompt longer than the context."""
import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OVERFLOW = "request ({n} tokens) exceeds the available context size ({ctx} tokens), try increasing it"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--alias", default="sensenova-loop-9b-q4-k-m")
    parser.add_argument("--list-devices", action="store_true")
    parser.add_argument("-c", type=int, default=65536)
    parser.add_argument("--record", default=None)
    parser.add_argument("--vision", action="store_true")
    parser.add_argument("--usage-file", default=None, help="prompt tokens to report, read at each request")
    parser.add_argument("--overflow-text", default=OVERFLOW, help="the error for a prompt longer than the context")
    parser.add_argument("--think-tokens", type=int, default=400, help="thinking without a budget")
    args, _ = parser.parse_known_args()
    if args.list_devices:
        print("Available devices:\n  MTL0: Apple M4 Pro (mock)")
        return

    key = os.environ.get("LLAMA_API_KEY")  # as llama-server: every endpoint but /health needs it, when set
    cache = {"messages": None}

    def tokens(text):
        return len(str(text).split())

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def refused(self):
            if not key or self.headers.get("Authorization") == f"Bearer {key}":
                return False
            self.send_error(401)
            return True

        def send_json(self, value, status=200):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self.send_json({"status": "ok"})
            elif self.refused():
                pass
            elif self.path == "/props":
                self.send_json({
                    "model_alias": args.alias,
                    "default_generation_settings": {"n_ctx": args.c},
                    "modalities": {"vision": args.vision},
                })
            elif self.path == "/v1/models":
                self.send_json({"data": [{"id": args.alias}]})
            else:
                self.send_error(404)

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.refused():
                return
            if self.path == "/tokenize":
                self.send_json({"tokens": list(range(tokens(request.get("content", ""))))})
                return
            if args.record:
                with open(args.record, "a", encoding="utf-8") as f:
                    f.write(json.dumps(request) + "\n")
            if request.get("stream"):
                self.stream(request)
            else:
                self.complete(request)

        def complete(self, request):
            messages = request.get("messages", [])
            n = sum(tokens(m.get("content") or "") for m in messages)
            if n > args.c:
                self.send_json({"error": {"code": 400, "type": "exceed_context_size_error",
                                          "message": args.overflow_text.format(n=n, ctx=args.c)}}, 400)
                return
            cached = request.get("cache_prompt", True) and messages == cache["messages"]
            cache["messages"] = messages
            max_tokens = request.get("max_tokens", 1024)
            message = {"role": "assistant", "content": ""}
            finish = "stop"
            thinking = (request.get("chat_template_kwargs") or {}).get("enable_thinking", True)
            if thinking:
                think = min(request.get("thinking_budget_tokens", args.think_tokens), args.think_tokens)
                message["reasoning_content"] = " ".join(["hmm"] * think)
            used = tokens(message.get("reasoning_content", ""))
            if request.get("tools"):
                name = request["tools"][0]["function"]["name"]
                message["tool_calls"] = [{"id": "call_0", "type": "function",
                                          "function": {"name": name, "arguments": json.dumps({"path": "notes.txt"})}}]
                finish = "tool_calls"
            elif used + 2 > max_tokens:
                finish = "length"
            else:
                message["content"] = "ready now"
            generated = max_tokens if request.get("ignore_eos") else min(max_tokens, used + 2)
            prompt_n = 1 if cached else n
            self.send_json({
                "id": "mock", "object": "chat.completion", "model": args.alias,
                "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {"prompt_tokens": n, "completion_tokens": generated, "total_tokens": n + generated},
                "timings": {"cache_n": n - prompt_n, "prompt_n": prompt_n, "prompt_ms": prompt_n * 2.0,
                            "prompt_per_second": 500.0, "predicted_n": generated, "predicted_ms": generated * 50.0,
                            "predicted_per_second": 20.0},
            })

        def stream(self, request):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for delta, finish in (({"role": "assistant", "content": "pong"}, None), ({}, "stop")):
                chunk = {
                    "id": "mock", "object": "chat.completion.chunk", "created": 0, "model": args.alias,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
                }
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            if args.usage_file and os.path.exists(args.usage_file):
                with open(args.usage_file, encoding="utf-8") as f:
                    prompt = int(f.read())
                chunk = {
                    "id": "mock", "object": "chat.completion.chunk", "created": 0, "model": args.alias, "choices": [],
                    "usage": {"prompt_tokens": prompt, "completion_tokens": 1, "total_tokens": prompt + 1},
                }
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")

    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
