#!/usr/bin/env python3
"""Small regression tests for the Thread code generator."""

from __future__ import annotations

import json
import unittest

import generate


def sample_config() -> dict:
    return {
        "package": {
            "name": "owner/thread",
            "version": "1.2.3",
            "description": "test",
            "license": "MIT",
            "realm": "shared",
            "authors": ["owner"],
            "repository": "https://github.com/owner/thread",
            "include": ["src", "default.project.json", "README.md", "LICENSE"],
        },
        "services": {
            "InventoryService": {
                "methods": {
                    "NoResult": {"arguments": [], "returns": []},
                    "Echo": {"arguments": ["value: string"], "returns": ["string"]},
                },
                "signals": {
                    "Changed": ["value: string"],
                    "Moved": {"arguments": ["position: Vector3"], "unreliable": True},
                },
                "properties": {"Capacity": "number"},
            }
        },
    }


class GeneratorTests(unittest.TestCase):
    def test_types_and_manifests_stay_in_sync(self) -> None:
        config = sample_config()
        generate.validate(config)
        client_types = generate.render_client_types(config)
        self.assertIn("NoResult: (self: InventoryService) -> ()", client_types)
        self.assertIn("Moved: Signal<Vector3>", client_types)

        typed_clients = generate.render_typed_clients(config)
        self.assertIn('(serviceName: "InventoryService", timeout: number?) -> InventoryService', typed_clients)
        self.assertIn("InventoryService: (timeout: number?) -> InventoryService", typed_clients)
        self.assertIn('Channel.BuildClient("InventoryService", timeout)', typed_clients)

        json_entries = json.loads(generate.render_manifest(config))["services"]["InventoryService"]["remotes"]
        self.assertEqual([entry["name"] for entry in json_entries], ["Capacity", "Changed", "Echo", "Moved", "NoResult"])
        self.assertEqual(json_entries[3]["class"], "UnreliableRemoteEvent")

        runtime_manifest = generate.render_runtime_manifest(config)
        positions = [runtime_manifest.index(f'Name = "{name}"') for name in ["Capacity", "Changed", "Echo", "Moved", "NoResult"]]
        self.assertEqual(positions, sorted(positions))

    def test_wally_manifest_metadata(self) -> None:
        rendered = generate.render_wally(sample_config())
        self.assertIn('repository = "https://github.com/owner/thread"', rendered)
        self.assertIn('"src",', rendered)
        self.assertIn('"default.project.json",', rendered)

    def test_duplicate_member_names_are_rejected(self) -> None:
        config = sample_config()
        config["services"]["InventoryService"]["signals"]["Echo"] = []
        with self.assertRaisesRegex(ValueError, "same member name"):
            generate.validate(config)

    def test_invalid_signal_options_are_rejected(self) -> None:
        config = sample_config()
        config["services"]["InventoryService"]["signals"]["Moved"]["typo"] = True
        with self.assertRaisesRegex(ValueError, "unknown options"):
            generate.validate(config)

    def test_documentation_version_badges_use_package_version(self) -> None:
        rendered = generate.render_doc_version('<span class="version">v0.0.1</span>', "1.2.3")
        self.assertEqual(rendered, '<span class="version">v1.2.3</span>')
        with self.assertRaisesRegex(ValueError, "missing its version badge"):
            generate.render_doc_version("<html></html>", "1.2.3")


if __name__ == "__main__":
    unittest.main()
