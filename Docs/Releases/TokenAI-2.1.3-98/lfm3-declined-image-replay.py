import json, sys, urllib.request

# The turn from the 2.1.3 (97) TestFlight report, after the app declines the
# model's generate_image call: the follow-up runs without tools, as the app
# does once a tool is declined in the turn. Pass "think" to enable thinking.
SYSTEM = "You are a helpful on-device assistant."
NEXT = "Need a animated background html code"
CALL = "<tool_call>\n<function=generate_image>\n<parameter=prompt>\napple\n</parameter>\n</function>\n</tool_call>"
RESULT = ("TOOL RESULT: generate_image\n\nThe tool has finished and the result below is available\n"
          "now. Answer the user's request in natural language using this result.\n"
          "Do not say that you are waiting for the tool.\n\n"
          "The user declined this generate_image request: they did not ask for an image. Answer their message in text.")
MESSAGES = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": "generate a apple image"},
            {"role": "assistant", "content": 'Here\'s the image of "apple".'},
            {"role": "user", "content": NEXT},
            {"role": "assistant", "content": CALL},
            {"role": "tool", "content": RESULT}]

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
think = len(sys.argv) > 2 and sys.argv[2] == "think"
html = 0
for seed in range(runs):
    body = {"messages": MESSAGES, "temperature": 0.1, "top_k": 50, "repeat_penalty": 1.1,
            "max_tokens": 1500, "seed": seed, "chat_template_kwargs": {"enable_thinking": think}}
    req = urllib.request.Request("http://127.0.0.1:18089/v1/chat/completions",
                                 json.dumps(body).encode(), {"Content-Type": "application/json"})
    text = json.load(urllib.request.urlopen(req, timeout=600))["choices"][0]["message"].get("content") or ""
    ok = "<html" in text.lower() or "<!doctype" in text.lower() or "@keyframes" in text
    html += ok and "<tool_call>" not in text
    print(f"seed={seed} html={ok} tool_call={'<tool_call>' in text} :: {text[:160]!r}")
print(f"== HTML without a tool call: {html}/{runs}")
