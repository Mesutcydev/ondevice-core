import json, sys, urllib.request

TOOLS = [
    ("calculator", "Evaluate arithmetic.", [("expression", "string", True)]),
    ("datetime", "Get the current date and time.", [("timezone", "string", False)]),
    ("unit_convert", "Convert a value between units.", [("value", "number", True), ("from", "string", True), ("to", "string", True)]),
    ("web_search", "Search the web or fetch a URL, subject to user permission.", [("query", "string", True)]),
    ("file_read", "Ask the user to choose a file.", [("prompt", "string", False)]),
    ("describe_image", "Describe the latest attached image.", []),
    ("knowledge_base", "Search the user's indexed documents.", [("query", "string", True)]),
    ("index_document", "Request permission to save text in the knowledge base.", [("text", "string", True), ("name", "string", False)]),
    ("generate_image", "Request permission to generate an image.", [("prompt", "string", True), ("negative_prompt", "string", False), ("steps", "integer", False), ("model", "string", False)]),
]

def tool_json(name, desc, params):
    props = ", ".join(f'"{p}": {{"type": "{t}"}}' for p, t, _ in params)
    req = ", ".join(f'"{p}"' for p, _, r in params if r)
    return (f'{{"name": "{name}", "description": "{desc}", "parameters": '
            f'{{"type": "object", "properties": {{{props}}}, "required": [{req}]}}}}')

SYSTEM = ("You are a helpful on-device assistant.\n\n"
          "Use an available tool only when needed. The app executes calls and returns results; never invent a result.\n"
          "Call one tool at a time. Web access, file selection, image generation, and repository changes remain subject to the app's existing permissions and review.\n"
          "<tools>\n" + "\n".join(tool_json(*t) for t in TOOLS) + "\n</tools>")

CALL = "<tool_call>\n<function=generate_image>\n<parameter=prompt>\na dog\n</parameter>\n</function>\n</tool_call>"
RESULT = ("TOOL RESULT: generate_image\n\nThe tool has finished and the result below is available\n"
          "now. Answer the user's request in natural language using this result.\n"
          "Do not say that you are waiting for the tool.\n\n"
          'Started generating an image for: "a dog" using SD Turbo. It will appear in the Image tab when ready.')
NEXT = "write a animation html"

def history(variant):
    if variant == "fresh":
        return [{"role": "system", "content": SYSTEM}, {"role": "user", "content": NEXT}]
    if variant == "collapsed":
        return [{"role": "system", "content": SYSTEM}, {"role": "user", "content": "generate a dog"},
                {"role": "assistant", "content": 'Here\'s the image of "a dog".'},
                {"role": "user", "content": NEXT}]
    if variant == "summarized":
        return [{"role": "system", "content": SYSTEM}, {"role": "user", "content": "generate a dog"},
                {"role": "assistant", "content": 'I generated an image of "a dog". It is shown above.'},
                {"role": "user", "content": NEXT}]
    m = [{"role": "system", "content": SYSTEM},
         {"role": "user", "content": "generate a dog"},
         {"role": "assistant", "content": CALL},
         {"role": "tool", "content": RESULT}]
    if variant == "before-empty":   # failed follow-up + uncaptioned image kept as empty turns
        m += [{"role": "assistant", "content": ""}, {"role": "assistant", "content": ""}]
    elif variant == "after":
        m += [{"role": "assistant", "content": 'Here\'s the image of "a dog".'}]
    # "before-dropped": empty turns omitted, tool result runs straight into the next request
    return m + [{"role": "user", "content": NEXT}]

def ask(messages, seed):
    body = {"messages": messages, "temperature": 0.1, "top_k": 50, "repeat_penalty": 1.1,
            "max_tokens": 700, "seed": seed, "chat_template_kwargs": {"enable_thinking": THINK}}
    req = urllib.request.Request("http://127.0.0.1:18089/v1/chat/completions",
                                 json.dumps(body).encode(), {"Content-Type": "application/json"})
    out = json.load(urllib.request.urlopen(req, timeout=300))["choices"][0]["message"]
    return (out.get("content") or "") + " | TOOLS " + json.dumps(out.get("tool_calls") or "") + " | THINK " + (out.get("reasoning_content") or "")[-200:]

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
THINK = sys.argv[2] == "think" if len(sys.argv) > 2 else False
VARIANTS = sys.argv[3].split(",") if len(sys.argv) > 3 else ["before-dropped", "before-empty", "after"]
if len(sys.argv) > 4:
    TOOLS[-1] = ("generate_image", sys.argv[4], TOOLS[-1][2])
    SYSTEM = SYSTEM.split("<tools>")[0] + "<tools>\n" + "\n".join(tool_json(*t) for t in TOOLS) + "\n</tools>"
for variant in VARIANTS:
    hits = 0
    for seed in range(runs):
        text = ask(history(variant), seed)
        hit = "generate_image" in text.split(" | THINK ")[0]
        hits += hit
        print(f"{variant} seed={seed} image_call={hit} :: {text[:140]!r}")
    print(f"== {variant}: generate_image {hits}/{runs}\n")
