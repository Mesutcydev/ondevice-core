#!/usr/bin/env python3
"""Prove every catalog pack is really downloadable.

For each entry in CoreAIZooCatalog it lists the exact subtree the app would
fetch, then issues a real ranged GET against the largest file's
`/resolve/<rev>/<path>` URL — the same URL the in-app downloader builds. A pack
only passes when the tree exists, carries an `.aimodel` plus `metadata.json`,
the summed size matches the catalog's recorded bytes, and the direct link
returns data.

    python3 scripts/verify_zoo_downloads.py            # all packs
    python3 scripts/verify_zoo_downloads.py zoo-qwen3.5-0.8b ...
"""
from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from audit_coreai_repos import fetch_tree, size_of

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "IOSLocalLLM" / "Models" / "CoreAIZooCatalog.swift"
RESOLVE = "https://huggingface.co/{repo}/resolve/{rev}/{path}"
UA = {"User-Agent": "coreai-zoo-verify/1.0"}

ENTRY_RE = re.compile(
    r"CoreAIZooModel\(\s*"
    r'id:\s*"(?P<id>[^"]+)",\s*'
    r'displayName:\s*"(?P<name>[^"]+)",\s*'
    r'subtitle:\s*"[^"]*",\s*'
    r'hfRepo:\s*"(?P<repo>[^"]+)",\s*'
    r'revision:\s*"(?P<rev>[^"]+)",\s*'
    r"pathPrefix:\s*(?P<prefix>nil|\"[^\"]*\"),\s*"
    r"approxDownloadBytes:\s*(?P<bytes>[0-9_]+),"
    r"\s*contextWindow:\s*(?P<context>[0-9_]+),"
    r".*?category:\s*\.(?P<category>\w+),",
    re.S,
)


def parse_catalog() -> list[dict]:
    text = CATALOG.read_text(encoding="utf-8")
    out = []
    for m in ENTRY_RE.finditer(text):
        prefix = m.group("prefix")
        out.append(
            {
                "id": m.group("id"),
                "name": m.group("name"),
                "repo": m.group("repo"),
                "rev": m.group("rev"),
                "prefix": None if prefix == "nil" else prefix.strip('"'),
                "bytes": int(m.group("bytes").replace("_", "")),
                "category": m.group("category"),
                "context": int(m.group("context").replace("_", "")),
            }
        )
    return out


def get_json(url: str):
    req = urllib.request.Request(url, headers={**UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.loads(resp.read().decode())


def probe_direct(repo: str, rev: str, path: str) -> tuple[bool, str]:
    """Ranged GET: proves the direct link serves bytes without pulling the file."""
    encoded = "/".join(urllib.parse.quote(p) for p in path.split("/"))
    url = RESOLVE.format(repo=repo, rev=rev, path=encoded)
    req = urllib.request.Request(url, headers={**UA, "Range": "bytes=0-1023"})
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read(1024)
            return (len(data) > 0, f"HTTP {resp.status}, {len(data)} bytes")
    except urllib.error.HTTPError as exc:
        return (False, f"HTTP {exc.code}")
    except Exception as exc:  # noqa: BLE001
        return (False, f"{type(exc).__name__}: {exc}")


def verify(entry: dict) -> bool:
    label = f"{entry['id']:34s}"
    tree = fetch_tree(entry["repo"], entry["rev"])
    if tree is None:
        print(f"FAIL {label} tree API unavailable")
        return False

    prefix = entry["prefix"] or ""
    norm = prefix if prefix.endswith("/") or not prefix else prefix + "/"
    files = [
        f
        for f in tree
        if f.get("type") == "file"
        and (not prefix or f["path"] == prefix or f["path"].startswith(norm))
        and not f["path"].lower().endswith((".md", ".gitattributes"))
    ]
    if not files:
        print(f"FAIL {label} subtree '{prefix}' is empty")
        return False

    normalized_prefix = prefix.rstrip("/")
    direct = normalized_prefix + "/" if normalized_prefix else ""
    relative = [f["path"][len(direct):].lower() for f in files]
    has_model = any(
        p.endswith((".aimodel", ".aimodelc"))
        or ".aimodel/" in p
        or ".aimodelc/" in p
        for p in relative
    )
    is_language = entry["category"] in {"officialRecipe", "chat"}
    is_classifier = entry["category"] == "classifier"
    # The language runtime receives the selected prefix itself. A metadata file
    # in some deeper sibling bundle is not sufficient; that was the production
    # bug that let parent trees install and then fail with BundleError 0.
    has_meta = (
        "metadata.json" in relative
        if is_language or is_classifier
        else any(p.endswith("metadata.json") for p in relative)
    )
    has_tokenizer = "tokenizer/tokenizer.json" in relative if is_language or is_classifier else True
    total = sum(size_of(f) for f in files)

    problems = []
    if not has_model:
        problems.append("no .aimodel")
    if not has_meta:
        problems.append(
            "metadata.json is not at the selected bundle root"
            if is_language or is_classifier
            else "no metadata.json"
        )
    if not has_tokenizer:
        problems.append("tokenizer/tokenizer.json is not at the selected bundle root")
    if total != entry["bytes"]:
        problems.append(f"size mismatch (tree {total:,} vs catalog {entry['bytes']:,})")
    if (is_language or is_classifier) and has_meta:
        try:
            metadata = get_json(RESOLVE.format(repo=entry["repo"], rev=entry["rev"], path=direct + "metadata.json"))
            expected_kind = "encoder" if is_classifier else "llm"
            if metadata.get("metadata_version") != "0.2" or metadata.get("kind") != expected_kind:
                problems.append(f"runtime metadata is not a {expected_kind} v0.2 bundle")
            exported_context = metadata.get("language", {}).get("max_context_length", 0)
            if entry["context"] > exported_context:
                problems.append(f"catalog context {entry['context']} exceeds export {exported_context}")
            if is_classifier and metadata.get("decision", {}).get("layout") not in {"julia", "laya"}:
                problems.append("classifier layout has no host adapter")
        except Exception as exc:  # noqa: BLE001
            problems.append(f"metadata read failed: {type(exc).__name__}: {exc}")

    biggest = max(files, key=size_of)
    ok, detail = probe_direct(entry["repo"], entry["rev"], biggest["path"])
    if not ok:
        problems.append(f"direct link failed: {detail}")

    status = "OK  " if not problems else "FAIL"
    print(
        f"{status} {label} {len(files):3d} files  {total/1e9:6.2f} GB  "
        f"direct={detail}  {'; '.join(problems)}"
    )
    return not problems


def main() -> int:
    entries = parse_catalog()
    # ENTRY_RE is order- and layout-sensitive; an entry it misses would
    # silently go unverified.
    declared = CATALOG.read_text(encoding="utf-8").count("CoreAIZooModel(")
    if len(entries) != declared:
        print(f"parsed {len(entries)} of {declared} CoreAIZooModel entries; fix the entry layout or ENTRY_RE")
        return 1
    wanted = set(sys.argv[1:])
    if wanted:
        missing = wanted - {e["id"] for e in entries}
        if missing:
            print(f"unknown catalog IDs: {', '.join(sorted(missing))}")
            return 2
        entries = [e for e in entries if e["id"] in wanted]
    if not entries:
        print("no catalog entries matched")
        return 2

    print(f"verifying {len(entries)} catalog packs\n")
    with ThreadPoolExecutor(max_workers=4) as pool:
        failures = [e["id"] for e, passed in zip(entries, pool.map(verify, entries)) if not passed]
    print()
    if failures:
        print(f"{len(failures)} FAILED: {', '.join(failures)}")
        return 1
    print(f"all {len(entries)} packs verified downloadable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
