#!/usr/bin/env python3
"""Collect pinned public Hub license evidence; never download model weights."""
import concurrent.futures
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def read_url(url):
    request = urllib.request.Request(url, headers={"User-Agent": "TokenAI-license-audit/1.0"})
    with urllib.request.urlopen(request, timeout=25) as response:
        return response.read(2_000_000)


def inventory():
    repos = {}
    for name in ("IOSLocalLLM/Models/AssistantModelCatalog.swift",
                 "IOSLocalLLM/Models/LFM3Catalog.swift",
                 "IOSLocalLLM/Services/ModelDownloadCenter.swift",
                 "IOSLocalLLM/Models/KittenVariant.swift",
                 "IOSLocalLLM/Services/ImageGenerationService.swift"):
        source = (ROOT / name).read_text()
        pattern = r'(?:repoID|repositoryID|id):\s*"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"'
        for repo in re.findall(pattern, source):
            repos.setdefault(repo, "main")
    source = (ROOT / "IOSLocalLLM/Models/CoreAIZooCatalog.swift").read_text()
    for repo, revision in re.findall(r'hfRepo:\s*"([^"]+)",\s*revision:\s*"([^"]+)"', source):
        repos[repo] = revision
    repos["FluidInference/silero-vad-coreml"] = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    repos["Edge0/Edge0-35B-A3B-preview"] = "main"
    repos["apple/FastVLM-0.5B"] = "main"
    return repos


def inspect(item):
    repo, revision = item
    entry = {"repository": repo, "requestedRevision": revision}
    try:
        metadata = json.loads(read_url(f"https://huggingface.co/api/models/{repo}/revision/{revision}"))
        entry["revision"] = metadata["sha"]
        card = metadata.get("cardData") or {}
        entry["licenseTag"] = card.get("license")
        entry["baseModels"] = card.get("base_model")
        entry["gated"] = metadata.get("gated", False)
        entry["licenseFiles"] = []
        for sibling in metadata.get("siblings", []):
            name = sibling["rfilename"]
            if "/" not in name and name.upper().startswith(("LICENSE", "NOTICE")):
                url = f"https://huggingface.co/{repo}/resolve/{metadata['sha']}/{urllib.parse.quote(name)}"
                data = read_url(url)
                entry["licenseFiles"].append({"path": name, "url": url,
                    "sha256": hashlib.sha256(data).hexdigest(), "text": data.decode("utf-8", errors="replace")})
        readme = read_url(f"https://huggingface.co/{repo}/resolve/{metadata['sha']}/README.md")
        entry["cardText"] = readme.decode("utf-8", errors="replace")
    except (OSError, ValueError, KeyError) as error:
        entry["error"] = str(error)
    return entry


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", action="store_true", help="Also inspect declared upstream bases and missing-base mappings")
    args = parser.parse_args()
    output = ROOT / "build/appstore-model-license-evidence.json"
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        entries = sorted(pool.map(inspect, inventory().items()), key=lambda entry: entry["repository"])
    if args.upstream:
        seen = {entry["repository"] for entry in entries}
        extra = {"microsoft/Phi-3.5-mini-instruct", "Qwen/Qwen3-VL-2B-Instruct", "Qwen/Qwen3-VL-4B-Instruct",
                 "google/embeddinggemma-300m", "google/gemma-2-2b-it", "openai/whisper-large-v3",
                 "snakers4/silero-vad", "stable-diffusion-v1-5/stable-diffusion-v1-5"}
        for _ in range(3):
            for entry in entries:
                bases = entry.get("baseModels") or []
                if isinstance(bases, str): bases = [bases]
                extra.update(base for base in bases if isinstance(base, str) and "/" in base)
            batch = sorted(extra - seen)
            if not batch: break
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                entries.extend(pool.map(inspect, ((repo, "main") for repo in batch)))
            seen.update(batch)
        entries.sort(key=lambda entry: entry["repository"])
    output.write_text(json.dumps({"auditDate": "2026-10-01", "models": entries}, indent=2) + "\n")
    for entry in entries:
        print(json.dumps({key: entry.get(key) for key in ("repository", "revision", "licenseTag", "baseModels", "gated", "error")}, ensure_ascii=False))
    print(f"Evidence: {output}")
