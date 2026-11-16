#!/usr/bin/env python3
"""Reproduce ABIs, bytecode packages and source hashes after forge build. Offline; no external packages."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APPLICATIONS = ("WishGardenTreasury", "WishGarden", "LegacyWishRegistry")


def encode(data):
    return json.dumps(data, indent=2) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    def write(relative, data):
        target = ROOT / relative
        content = encode(data)
        if args.check:
            if not target.is_file() or target.read_text() != content:
                raise SystemExit("Artifact differs: " + relative)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        print(("Checked " if args.check else "Exported ") + relative)

    for name in (*APPLICATIONS, "BaseBurnReceiver"):
        artifact_path = ROOT / "out" / (name + ".sol") / (name + ".json")
        if not artifact_path.is_file():
            raise SystemExit("Run forge build first: " + name)
        data = json.loads(artifact_path.read_text())
        if data["bytecode"].get("linkReferences") or "__" in data["bytecode"]["object"]:
            raise SystemExit("Unlinked artifact: " + name)
        is_base = name == "BaseBurnReceiver"
        prefix = "base/artifacts" if is_base else "docs/abi"
        write(prefix + "/" + name + ".json", data["abi"])
        sources = data["metadata"]["sources"]
        package = {
            "contract": name,
            "chainId": 8453 if is_base else 1,
            "deploymentStatus": "not deployed by this source assignment",
            "compiler": data["metadata"]["compiler"],
            "settings": data["metadata"]["settings"],
            "abi": data["abi"],
            "creationBytecode": data["bytecode"]["object"],
            "deployedBytecodeTemplate": data["deployedBytecode"]["object"],
            # solc AST IDs differ between incremental and clean compilation. Keep the
            # immutable groups/offsets, sorted by location, rather than unstable AST keys.
            "immutableReferences": sorted(
                [sorted(group, key=lambda span: span["start"]) for group in data["deployedBytecode"].get("immutableReferences", {}).values()],
                key=lambda group: group[0]["start"],
            ),
            "sourceSHA256": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in sorted(sources)},
            "constructorArguments": "See base/README.md; real confirmed addresses required" if is_base else "See docs/deployment/manifest-handoff.json",
        }
        write(("base/artifacts" if is_base else "docs/deployment/artifacts") + "/" + name + ".deployment.json", package)


if __name__ == "__main__":
    main()
