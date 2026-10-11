import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("repack", Path(__file__).parents[1] / "repack_edge0_35b.py")
repack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repack)


class RepackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "packed"
        header, self.payloads, cursor = {}, {}, 0
        for layer in range(2):
            for number, (projection, part) in enumerate(repack.PARTS):
                name = repack.tensor_name(layer, projection, part)
                weight = part == "weight"
                shape, dtype, width = ([4, 2, 2], "U32", 4) if weight else ([4, 2, 1], "BF16", 2)
                row = 16 if weight else 4
                payload = b"".join(bytes([1 + layer * 40 + number * 4 + expert]) * row for expert in range(4))
                self.payloads[name] = payload
                header[name] = dict(dtype=dtype, shape=shape, data_offsets=[cursor, cursor + len(payload)])
                cursor += len(payload)
        self.payloads["resident.weight"] = b"abcdefgh"
        header["resident.weight"] = dict(dtype="U32", shape=[2], data_offsets=[cursor, cursor + 8])
        blob = json.dumps(header).encode()
        self.shard = self.source / "model.safetensors"
        self.shard.write_bytes(struct.pack("<Q", len(blob)) + blob + b"".join(self.payloads.values()))
        (self.source / "model.safetensors.index.json").write_text(json.dumps({
            "weight_map": {name: self.shard.name for name in header}
        }))
        for name in repack.METADATA:
            (self.source / name).write_bytes(b"metadata")

    def tearDown(self):
        self.temporary.cleanup()

    def pack_fixture(self):
        with contextlib.redirect_stdout(io.StringIO()):
            repack.pack(self.source, self.output, require_release=False)

    def test_every_expert_and_resident_byte_is_preserved(self):
        original = self.shard.read_bytes()
        self.pack_fixture()
        manifest = json.loads((self.output / "experts.json").read_text())
        for layer in range(2):
            data = (self.output / f"experts-L{layer:02d}.bin").read_bytes()
            for expert in range(4):
                for part in manifest["parts"]:
                    projection, kind = part["name"].split(".")
                    expected = self.payloads[repack.tensor_name(layer, projection, kind)]
                    row = part["bytes"]
                    start = expert * manifest["block_bytes"] + part["offset"]
                    self.assertEqual(data[start:start + row], expected[expert * row:(expert + 1) * row])
        with repack_source(self.output) as packed:
            entry = packed.entries["resident.weight"]
            data = io.BytesIO()
            packed.copy(entry, data, repack.hashlib.sha256())
            self.assertEqual(data.getvalue(), self.payloads["resident.weight"])
        for name, digest in manifest["file_sha256"].items():
            self.assertEqual(repack.checksum(self.output / name), digest)
        self.assertEqual(self.shard.read_bytes(), original)
        self.assertFalse((self.output / self.shard.name).exists())

    def test_refuses_existing_destination_without_overwriting(self):
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_text("existing")
        with self.assertRaises(ValueError):
            self.pack_fixture()
        self.assertEqual(marker.read_text(), "existing")

    def test_interruption_does_not_publish_partial_model(self):
        from unittest.mock import patch
        with patch.object(repack.Source, "copy", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.pack_fixture()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".packed.partial-*")))

    def test_rejects_outside_shard_and_duplicate_index_entries(self):
        index = self.source / "model.safetensors.index.json"
        index.write_text('{"weight_map":{"x":"../escape.safetensors"}}')
        with self.assertRaises(ValueError):
            repack.Source(self.source)
        index.write_text('{"weight_map":{"x":"model.safetensors","x":"other.safetensors"}}')
        with self.assertRaises(ValueError):
            repack.Source(self.source)

    def test_rejects_truncated_payload_before_output(self):
        data = self.shard.read_bytes()
        self.shard.write_bytes(data[:-1])
        with self.assertRaises(ValueError):
            self.pack_fixture()
        self.assertFalse(self.output.exists())

    def test_output_cannot_be_inside_source(self):
        with self.assertRaises(ValueError):
            repack.pack(self.source, self.source / "new" / "packed", require_release=False)
        self.assertFalse((self.source / "new").exists())

    def test_metadata_reads_are_bounded(self):
        path = self.source / "oversized.json"
        path.write_bytes(b" " * 65)
        with self.assertRaises(ValueError):
            repack.read_json_file(path, maximum=64)

    def test_release_config_declares_eight_experts_while_runtime_uses_four(self):
        from types import SimpleNamespace
        for name, size in repack.SHARD_SIZES.items():
            with (self.source / name).open("wb") as handle:
                handle.truncate(size)
        config = dict(architectures=["Qwen3_5MoeForConditionalGeneration"], text_config=dict(
            hidden_size=2048, num_hidden_layers=40, num_experts=256, num_experts_per_tok=8))
        path = self.source / "config.json"
        path.write_text(json.dumps(config))
        parts = []
        for projection, kind in repack.PARTS:
            down, weight = projection == "down_proj", kind == "weight"
            shape = ([2048, 64] if down else [512, 256]) if weight else ([2048, 8] if down else [512, 32])
            parts.append(dict(name=f"{projection}.{kind}", shape=shape, dtype="U32" if weight else "BF16"))
        source = SimpleNamespace(directory=self.source, handles=dict.fromkeys(repack.SHARD_SIZES))
        repack.validate_release(source, 40, 256, parts, 1_769_472)
        config["text_config"]["num_experts_per_tok"] = 4
        path.write_text(json.dumps(config))
        with self.assertRaises(ValueError):
            repack.validate_release(source, 40, 256, parts, 1_769_472)


@contextlib.contextmanager
def repack_source(directory):
    source = repack.Source(directory)
    try:
        yield source
    finally:
        source.close()


if __name__ == "__main__":
    unittest.main()
