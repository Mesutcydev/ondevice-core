#!/usr/bin/env python3
"""Prepare a verified native 35B import without changing any tensor bytes.

Uses only the Python standard library. The source checkpoint is read-only;
the destination is published only after all output payload checksums pass.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import tempfile

FORMAT = "ondevice-edge0-35b-repack-v1"
REPO = "Edge0/Edge0-35B-A3B-preview"
REVISION = "1ff9f4478890faec0368c5463b621d1036d5b518"
# The audited public revision has the same payload hashes; only README differs.
REPACK_REVISIONS = {REVISION, "3fe15cbf2bd5bbcdfd611035e1ac88971ff1cdab"}
METADATA = ("config.json", "generation_config.json", "tokenizer.json",
            "tokenizer_config.json", "chat_template.jinja", "lora_edge0_35b.safetensors")
PARTS = tuple((projection, part) for projection in ("gate_proj", "up_proj", "down_proj")
              for part in ("weight", "scales", "biases"))
SHARD_SIZES = {
    "model-00001-of-00004.safetensors": 4_395_019_264,
    "model-00002-of-00004.safetensors": 5_368_472_749,
    "model-00003-of-00004.safetensors": 5_368_324_139,
    "model-00004-of-00004.safetensors": 4_377_211_365,
}
CHUNK = 1 << 20


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode_json(data):
    return json.loads(data, object_pairs_hook=unique_object)


def read_json_file(path, maximum=64 * CHUNK):
    if path.stat().st_size > maximum:
        raise ValueError(f"oversized JSON metadata: {path.name}")
    return decode_json(path.read_bytes())


def local_file(directory, name):
    if not isinstance(name, str) or not name or Path(name).name != name or "\\" in name or ".." in name:
        raise ValueError("checkpoint contains an unsafe file reference")
    path = directory / name
    if not path.is_file() or path.resolve().parent != directory.resolve():
        raise ValueError(f"missing or external checkpoint file: {name}")
    return path


def tensor_name(layer, projection, part):
    return f"language_model.model.layers.{layer}.mlp.switch_mlp.{projection}.{part}"


class Source:
    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.entries = {}
        self.handles = {}
        try:
            weight_map = read_json_file(local_file(self.directory, "model.safetensors.index.json"))["weight_map"]
            if not isinstance(weight_map, dict) or not weight_map:
                raise ValueError("empty checkpoint index")
            headers = {}
            for name in sorted(set(weight_map.values())):
                path = local_file(self.directory, name)
                handle = path.open("rb")
                self.handles[name] = handle
                length_bytes = handle.read(8)
                if len(length_bytes) != 8:
                    raise ValueError(f"truncated safetensors: {name}")
                length = struct.unpack("<Q", length_bytes)[0]
                if not 0 < length <= 64 * CHUNK or length + 8 > path.stat().st_size:
                    raise ValueError(f"invalid safetensors header: {name}")
                headers[name] = (decode_json(handle.read(length)), length + 8, path.stat().st_size)
            widths = {"U32": 4, "BF16": 2, "F16": 2, "F32": 4}
            for tensor, shard in weight_map.items():
                header, base, size = headers[shard]
                entry = header[tensor]
                shape, dtype = entry["shape"], entry["dtype"]
                start, end = entry["data_offsets"]
                if (not shape or any(type(d) is not int or d <= 0 for d in shape)
                        or dtype not in widths or type(start) is not int or type(end) is not int
                        or start < 0 or end < start or base + end > size
                        or end - start != math.prod(shape) * widths[dtype]):
                    raise ValueError(f"invalid tensor geometry or range: {tensor}")
                self.entries[tensor] = (shard, base + start, end - start, dtype, shape)
        except BaseException:
            self.close()
            raise

    def close(self):
        for handle in self.handles.values():
            handle.close()

    def copy(self, entry, output, digest, *, offset=0, count=None):
        shard, start, total, _, _ = entry
        count = total if count is None else count
        if offset < 0 or count < 0 or offset + count > total:
            raise ValueError("invalid source tensor slice")
        source = self.handles[shard]
        source.seek(start + offset)
        while count:
            data = source.read(min(CHUNK, count))
            if not data:
                raise ValueError("source checkpoint was truncated during packing")
            output.write(data)
            digest.update(data)
            count -= len(data)


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(CHUNK), b""):
            digest.update(data)
    return digest.hexdigest()


def describe(source):
    names = {name for name in source.entries if ".mlp.switch_mlp." in name}
    layers = 1 + max(int(name.split(".layers.")[1].split(".")[0]) for name in names)
    experts = source.entries[tensor_name(0, "gate_proj", "weight")][4][0]
    if names != {tensor_name(layer, projection, part) for layer in range(layers)
                 for projection, part in PARTS}:
        raise ValueError("incomplete expert tensor inventory")
    parts, cursor = [], 0
    for projection, part in PARTS:
        _, _, total, dtype, shape = source.entries[tensor_name(0, projection, part)]
        if len(shape) != 3 or shape[0] != experts or total % experts:
            raise ValueError("invalid expert axis")
        row = total // experts
        for layer in range(layers):
            entry = source.entries[tensor_name(layer, projection, part)]
            if entry[2:] != (total, dtype, shape):
                raise ValueError("expert layouts differ between layers")
        parts.append(dict(name=f"{projection}.{part}", dtype=dtype,
                          shape=shape[1:], offset=cursor, bytes=row))
        cursor += row
    return layers, experts, parts, cursor


def validate_release(source, layers, experts, parts, block):
    config = read_json_file(local_file(source.directory, "config.json"), 65_536)
    text = config.get("text_config", config)
    if ("Qwen3_5MoeForConditionalGeneration" not in config.get("architectures", [])
            or text.get("hidden_size") != 2048 or text.get("num_hidden_layers") != 40
            or text.get("num_experts") != 256 or text.get("num_experts_per_tok") != 8
            or layers != 40 or experts != 256 or block != 1_769_472):
        raise ValueError("source does not match the supported Edge0-35B release")
    if set(source.handles) != set(SHARD_SIZES):
        raise ValueError("source must contain exactly the four pinned release shards")
    for name, size in SHARD_SIZES.items():
        if local_file(source.directory, name).stat().st_size != size:
            raise ValueError(f"wrong pinned shard size: {name}")
    for part in parts:
        projection, kind = part["name"].split(".")
        down, weight = projection == "down_proj", kind == "weight"
        shape = ([2048, 64] if down else [512, 256]) if weight else ([2048, 8] if down else [512, 32])
        if part["shape"] != shape or part["dtype"] != ("U32" if weight else "BF16"):
            raise ValueError("expert quantization differs from the pinned release")
    for name in METADATA:
        local_file(source.directory, name)


def finish_file(handle, path, digest):
    handle.flush()
    os.fsync(handle.fileno())
    expected = digest.hexdigest()
    if checksum(path) != expected:
        raise ValueError(f"output verification failed: {path.name}")
    return expected


def pack(source_directory, destination, *, require_release=True):
    """Internal fixture tests can use small geometry; the CLI always pins the release."""
    destination = Path(destination).resolve()
    source_directory = Path(source_directory).resolve()
    if destination == source_directory or source_directory in destination.parents:
        raise ValueError("output must be outside the source checkpoint")
    if destination.exists() or destination.is_symlink():
        raise ValueError("destination already exists; choose a new output directory")
    destination.parent.mkdir(parents=True, exist_ok=True)
    source = Source(source_directory)
    try:
        layers, experts, parts, block = describe(source)
        if require_release:
            validate_release(source, layers, experts, parts, block)
        resident = sorted(name for name in source.entries if ".mlp.switch_mlp." not in name)
        payload = sum(source.entries[name][2] for name in resident)
        metadata_bytes = sum(local_file(source.directory, name).stat().st_size for name in METADATA)
        if shutil.disk_usage(destination.parent).free < layers * experts * block + payload + metadata_bytes + CHUNK:
            raise ValueError("not enough free space for the complete verified output")
        with tempfile.TemporaryDirectory(prefix=f".{destination.name}.partial-", dir=destination.parent) as staging:
            staging = Path(staging)
            digests = {}
            for layer in range(layers):
                name = f"experts-L{layer:02d}.bin"
                path, digest = staging / name, hashlib.sha256()
                with path.open("wb") as output:
                    for expert in range(experts):
                        for projection, part in PARTS:
                            entry = source.entries[tensor_name(layer, projection, part)]
                            row = entry[2] // experts
                            source.copy(entry, output, digest, offset=expert * row, count=row)
                    digests[name] = finish_file(output, path, digest)
                print(f"Verified expert layer {layer + 1}/{layers}", flush=True)
            header, cursor = {}, 0
            for name in resident:
                _, _, count, dtype, shape = source.entries[name]
                header[name] = dict(dtype=dtype, shape=shape, data_offsets=[cursor, cursor + count])
                cursor += count
            blob = json.dumps(header, separators=(",", ":")).encode()
            blob += b" " * (-len(blob) % 8)
            prefix = struct.pack("<Q", len(blob)) + blob
            path, digest = staging / "resident.safetensors", hashlib.sha256(prefix)
            with path.open("wb") as output:
                output.write(prefix)
                for name in resident:
                    source.copy(source.entries[name], output, digest)
                digests[path.name] = finish_file(output, path, digest)
            index = {"weight_map": {name: "resident.safetensors" for name in resident}}
            (staging / "model.safetensors.index.json").write_text(json.dumps(index))
            for name in METADATA + ("prerouter_edge0_35b.safetensors", "README.md", "LICENSE", "NOTICE"):
                if (source.directory / name).exists():
                    shutil.copyfile(local_file(source.directory, name), staging / name)
            manifest = dict(format=FORMAT, source_repo=REPO, source_revision=REVISION,
                            layers=layers, experts_per_layer=experts, block_bytes=block,
                            parts=parts, file_sha256=digests)
            (staging / "experts.json").write_text(json.dumps(manifest, indent=2) + "\n")
            # All output payloads are verified. Publish the directory in one rename.
            if destination.exists():
                raise ValueError("destination was created during conversion")
            staging.rename(destination)
        print(f"Verified pack ready: {destination}", flush=True)
    finally:
        source.close()


def verify(directory):
    directory = Path(directory).resolve()
    manifest = read_json_file(local_file(directory, "experts.json"), 65_536)
    if (manifest["format"] != FORMAT or manifest["source_repo"] != REPO
            or manifest["source_revision"] not in REPACK_REVISIONS or manifest["layers"] != 40
            or manifest["experts_per_layer"] != 256 or manifest["block_bytes"] != 1_769_472):
        raise ValueError("unsupported repacked release")
    expected = {"resident.safetensors"} | {f"experts-L{layer:02d}.bin" for layer in range(40)}
    if set(manifest["file_sha256"]) != expected:
        raise ValueError("incomplete checksum inventory")
    cursor, expected_parts = 0, []
    for projection, kind in PARTS:
        down, weight = projection == "down_proj", kind == "weight"
        shape = ([2048, 64] if down else [512, 256]) if weight else ([2048, 8] if down else [512, 32])
        count = 524_288 if weight else 32_768
        expected_parts.append(dict(name=f"{projection}.{kind}", dtype="U32" if weight else "BF16",
                                   shape=shape, offset=cursor, bytes=count))
        cursor += count
    if manifest["parts"] != expected_parts:
        raise ValueError("unsupported expert block layout")
    for name, digest in sorted(manifest["file_sha256"].items()):
        path = local_file(directory, name)
        if name.startswith("experts-") and path.stat().st_size != 256 * 1_769_472:
            raise ValueError(f"wrong expert layer size: {name}")
        if checksum(path) != digest:
            raise ValueError(f"checksum mismatch: {name}")
        print(f"Verified {name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    convert = commands.add_parser("pack", help="convert the pinned checkpoint to a new import folder")
    convert.add_argument("source")
    convert.add_argument("destination")
    check = commands.add_parser("verify", help="verify all converted payload checksums")
    check.add_argument("directory")
    args = parser.parse_args()
    try:
        if args.command == "pack":
            pack(args.source, args.destination)
        else:
            verify(args.directory)
    except (ValueError, KeyError, OSError, TypeError) as error:
        parser.exit(1, f"Repack failed: {error}\n")


if __name__ == "__main__":
    main()
