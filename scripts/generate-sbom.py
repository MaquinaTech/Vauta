#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Writes a CycloneDX 1.5 JSON software bill of materials for Vauta (Python standard library only).

    scripts/generate-sbom.py --version 0.9.0 --output dist/Vauta-0.9.0.sbom.cdx.json

Contents:
  * the application (Apache-2.0);
  * the two bundled speaker-separation models (CC-BY-4.0): source repository, revision, checkpoint SHA-256 and the
    SHA-256 of every file of the bundled Core ML folder (as `vauta:file-sha256:<path>` properties), plus the
    folder's tree hash;
  * the Apple system frameworks and the system SQLite its sources import or Package.swift links, derived from the code
    (an unknown module stops the script; no version pinned: they belong to the user's macOS).
  * the one third-party code package, the pinned MaquinaTech mlx-swift fork (MIT), with its vendored licences, and its own
    dependency swift-numerics (Apache-2.0), read from Package.resolved; and the optional search model (EmbeddingGemma 2,
    Apache-2.0), which is NOT bundled: it is downloaded only when the user asks (the pinned hashes are listed).
Package.swift may declare exactly that one package; this script fails if it declares anything else.

The tree hash of each bundled model is recomputed here and compared with the constant pinned in
Sources/VautaCore/Diarization/DiarizationModels.swift; any difference stops the script, so the SBOM cannot
describe models other than the ones the app verifies at run time.
"""
import argparse
import hashlib
import json
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = ROOT / "Sources/VautaCore/Resources/Models"
PINS_SWIFT = ROOT / "Sources/VautaCore/Diarization/DiarizationModels.swift"

# Provenance of the bundled weights. Mirrors NOTICE (the checkpoint hashes are also written into each model's metadata).
MODELS = [
    {
        "folder": "Segmentation_community1_fp16.mlmodelc",
        "name": "pyannote community-1 speaker segmentation (Core ML FP16)",
        "source": "https://huggingface.co/pyannote/speaker-diarization-community-1",
        "revision": "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee",
        "checkpoint_file": "segmentation/pytorch_model.bin",
        "checkpoint_sha256": "7ad24338d844fb95985486eb1a464e32d229f6d7a03c9abe60f978bacf3f816e",
        "authors": "Alexis Plaquet, Hervé Bredin (pyannote.audio)",
    },
    {
        "folder": "WeSpeakerResNet34LM_fp16.mlmodelc",
        "name": "WeSpeaker ResNet34-LM speaker embedding (Core ML FP16)",
        "source": "https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM",
        "revision": "837717ddb9ff5507820346191109dc79c958d614",
        "checkpoint_file": "pytorch_model.bin",
        "checkpoint_sha256": "366edf44f4c80889a3eb7a9d7bdf02c4aede3127f7dd15e274dcdb826b143c56",
        "authors": "WeSpeaker authors, distributed for pyannote.audio by Hervé Bredin",
    },
]

# Every module the sources import, or the manifest links, must be named here (or be Vauta's own); an unknown one stops the
# script, so the list of Apple frameworks in the SBOM cannot fall behind the code. Value: the name shown in the SBOM.
OWN_MODULES = {"VautaCore", "VautaMLX"}
# Modules that come from the one third-party package (listed as its components, not as Apple frameworks).
PACKAGE_MODULES = {"MLX", "MLXFast", "MLXNN", "MLXFFT"}
KNOWN_MODULES = {
    "Foundation": "Foundation", "SwiftUI": "SwiftUI", "AppKit": "AppKit", "Observation": "Observation",
    "AVFoundation": "AVFoundation", "CryptoKit": "CryptoKit", "Speech": "Speech", "Accelerate": "Accelerate",
    "CoreAudio": "CoreAudio", "NaturalLanguage": "NaturalLanguage", "UniformTypeIdentifiers": "UniformTypeIdentifiers",
    "ServiceManagement": "ServiceManagement", "CoreMedia": "CoreMedia", "Security": "Security", "EventKit": "EventKit",
    "CoreML": "CoreML", "UserNotifications": "UserNotifications", "Translation": "Translation",
    "SQLite3": "SQLite3 (system library)", "sqlite3": "SQLite3 (system library)", "CoreGraphics": "CoreGraphics",
    "Carbon": "Carbon (HIToolbox)", "FoundationModels": "FoundationModels", "Synchronization": "Synchronization",
    "os": "os (unified logging)", "Darwin": "Darwin (system C library)", "LocalAuthentication": "LocalAuthentication",
    "Compression": "Compression", "CommonCrypto": "CommonCrypto",
    "Metal": "Metal", "Dispatch": "Dispatch (libdispatch)", "IOKit": "IOKit", "CoreServices": "CoreServices", "CoreText": "CoreText",
    "ImageIO": "ImageIO", "PDFKit": "PDFKit", "QuickLookUI": "QuickLookUI", "Vision": "Vision",
}


def system_frameworks() -> list:
    """The Apple frameworks and system libraries the sources import or Package.swift links, by display name."""
    modules = set()
    for path in (ROOT / "Sources").rglob("*.swift"):
        for line in path.read_text(encoding="utf-8").splitlines():
            found = re.match(r"\s*(?:@\w+\s+)*(?:(?:public|internal|package)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z0-9_]+)", line)
            if found:
                modules.add(found.group(1))
    manifest = (ROOT / "Package.swift").read_text(encoding="utf-8")
    modules.update(re.findall(r'\.linked(?:Framework|Library)\("([^"]+)"\)', manifest))
    unknown = sorted(modules - OWN_MODULES - PACKAGE_MODULES - KNOWN_MODULES.keys())
    if unknown:
        sys.exit(f"error: the sources import or link modules the SBOM does not name: {unknown}. Add them to KNOWN_MODULES.")
    return sorted({KNOWN_MODULES[m] for m in modules if m in KNOWN_MODULES})


def search_model_pins() -> dict:
    """The pinned revision and hashes of the optional search model, read from the Swift source (the single source of truth)."""
    text = (ROOT / "Sources/VautaCore/SearchModel/SearchModelManifest.swift").read_text(encoding="utf-8")

    def constant(name: str) -> str:
        found = re.search(r'static let ' + name + r' = "([^"]+)"', text)
        if not found:
            sys.exit(f"error: could not read {name} from SearchModelManifest.swift")
        return found.group(1)

    return {"revision": constant("revision"), "source_sha256": constant("sourceSHA256"),
            "assembled_sha256": constant("assembledSHA256"), "tokenizer_sha256": constant("tokenizerSHA256")}


SEARCH_MODEL = search_model_pins()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def folder_files(folder: Path):
    """(relative path, sha256) of every file, in UTF-8 byte order of the path; refuses symbolic links."""
    entries = []
    for path in folder.rglob("*"):
        if path.is_symlink():
            sys.exit(f"error: symbolic link in {folder}: {path}")
        if path.is_file():
            entries.append((path.relative_to(folder).as_posix(), sha256_file(path)))
    entries.sort(key=lambda entry: entry[0].encode("utf-8"))
    return entries


def tree_hash(entries) -> str:
    """Same algorithm as DiarizationModels.treeHash(of:) and tools/convert-diarization-models."""
    digest = hashlib.sha256()
    for rel, file_hash in entries:
        digest.update(f"{rel}\n{file_hash}\n".encode("utf-8"))
    return digest.hexdigest()


def pinned_hashes() -> dict:
    text = PINS_SWIFT.read_text(encoding="utf-8")
    found = re.findall(r'folder:\s*"([^"]+)",\s*treeSHA256:\s*"([0-9a-f]{64})"', text)
    if len(found) != 2:
        sys.exit("error: could not read the two pinned tree hashes from DiarizationModels.swift")
    return dict(found)


# The one package Vauta allows and what it brings (scripts/check-dependencies.sh enforces the same pins).
FORK_URL = "https://github.com/MaquinaTech/mlx-swift.git"
NUMERICS_URL = "https://github.com/apple/swift-numerics"


def resolved_pins() -> dict:
    """{location: (revision, version or None)} from Package.resolved; stops unless it is exactly the fork and swift-numerics."""
    pins = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))["pins"]
    found = {p["location"]: (p["state"]["revision"], p["state"].get("version")) for p in pins}
    if set(found) != {FORK_URL, NUMERICS_URL}:
        sys.exit(f"error: Package.resolved has {sorted(found)}; the SBOM describes exactly the mlx-swift fork and swift-numerics.")
    return found


def check_packages() -> None:
    manifest = (ROOT / "Package.swift").read_text(encoding="utf-8")
    declared = re.findall(r"\.package\s*\(\s*url:\s*\"([^\"]+)\"", manifest)
    if declared != [FORK_URL]:
        sys.exit(f"error: Package.swift declares {declared}; the SBOM describes exactly {FORK_URL}. Update this script.")


# The fields this script may write, per CycloneDX 1.5 object (the 1.5 schema forbids any other: for example
# `evidence.occurrences[].additionalContext` only exists from 1.6). build() checks its own output against this table, so an edit
# that needs a newer spec version cannot slip through silently. The official bom-1.5.schema.json is the reference.
ALLOWED_15 = {
    "document": {"bomFormat", "specVersion", "serialNumber", "version", "metadata", "components", "dependencies"},
    "metadata": {"timestamp", "tools", "component"},
    "component": {"type", "bom-ref", "name", "version", "author", "supplier", "description", "licenses", "purl",
                  "externalReferences", "hashes", "properties"},
    "property": {"name", "value"},
    "hash": {"alg", "content"},
    "reference": {"type", "url"},
    "dependency": {"ref", "dependsOn"},
}


def check_cyclonedx_15(document: dict) -> None:
    def need(kind: str, obj: dict, where: str) -> None:
        extra = set(obj) - ALLOWED_15[kind]
        if extra:
            sys.exit(f"error: {where} has fields CycloneDX 1.5 does not allow: {sorted(extra)}")

    need("document", document, "the document")
    need("metadata", document["metadata"], "metadata")
    components = [document["metadata"]["component"]] + document["components"]
    for component in components:
        need("component", component, f"component {component['name']}")
        for prop in component.get("properties", []):
            need("property", prop, f"a property of {component['name']}")
        for digest in component.get("hashes", []):
            need("hash", digest, f"a hash of {component['name']}")
        for ref in component.get("externalReferences", []):
            need("reference", ref, f"a reference of {component['name']}")
    for dependency in document["dependencies"]:
        need("dependency", dependency, "a dependency")
    if document["specVersion"] != "1.5":
        sys.exit("error: this script writes CycloneDX 1.5")


def build(version: str, timestamp: str) -> dict:
    check_packages()
    pins = pinned_hashes()
    resolved = resolved_pins()
    fork_revision, _ = resolved[FORK_URL]
    numerics_revision, numerics_version = resolved[NUMERICS_URL]
    app_ref = f"pkg:generic/vauta@{version}"
    components = []
    for model in MODELS:
        folder = MODELS_DIR / model["folder"]
        if not folder.is_dir():
            sys.exit(f"error: missing {folder}")
        entries = folder_files(folder)
        computed = tree_hash(entries)
        if computed != pins.get(model["folder"]):
            sys.exit(f"error: {model['folder']} tree hash {computed} differs from the pinned {pins.get(model['folder'])}")
        components.append({
            "type": "machine-learning-model",
            "bom-ref": f"model:{model['folder']}",
            "name": model["name"],
            "version": model["revision"],
            "author": model["authors"],
            "licenses": [{"license": {"id": "CC-BY-4.0"}}],
            "purl": f"pkg:huggingface/{model['source'].split('huggingface.co/')[1]}@{model['revision']}",
            "externalReferences": [{"type": "distribution", "url": model["source"]}],
            "hashes": [{"alg": "SHA-256", "content": computed}],
            "properties": [
                {"name": "vauta:bundled-folder", "value": model["folder"]},
                {"name": "vauta:hash-kind", "value": "tree hash over every file name and content, as verified by the app before loading"},
                {"name": "vauta:source-checkpoint-file", "value": model["checkpoint_file"]},
                {"name": "vauta:source-checkpoint-sha256", "value": model["checkpoint_sha256"]},
                {"name": "vauta:modification", "value": "converted to Core ML FP16 with tools/convert-diarization-models; see NOTICE"},
            ] + [{"name": f"vauta:file-sha256:{rel}", "value": h} for rel, h in entries],
        })
    components += [
        {
            "type": "library",
            "bom-ref": "pkg:github/MaquinaTech/mlx-swift@" + fork_revision,
            "name": "mlx-swift (MaquinaTech fork)",
            "version": fork_revision,
            "author": "ml-explore (Apple Inc.); fork patches by the Vauta project",
            "licenses": [{"license": {"id": "MIT"}}],
            "purl": "pkg:github/MaquinaTech/mlx-swift@" + fork_revision,
            "externalReferences": [{"type": "vcs", "url": "https://github.com/MaquinaTech/mlx-swift"},
                                   {"type": "other", "url": "https://github.com/ml-explore/mlx-swift"}],
            "properties": [
                {"name": "vauta:upstream", "value": "ml-explore/mlx-swift 0.32.3 (19601207e9a0de51e03ee6ec0c3c5f3784275075), vendoring mlx v0.32.2"},
                {"name": "vauta:modification", "value": "runtime kernel compilation (no metallib) and an exact kernel table; see NOTICE and docs/SEARCH_MODEL.md"},
                {"name": "vauta:licences", "value": "THIRD_PARTY_LICENSES.txt lists every licence file of the compiled packages"},
            ],
        },
        {
            "type": "library",
            "bom-ref": "pkg:github/apple/swift-numerics@" + numerics_revision,
            "name": "swift-numerics",
            "version": numerics_version or numerics_revision,
            "author": "Apple Inc.",
            "licenses": [{"license": {"id": "Apache-2.0"}}],
            "purl": "pkg:github/apple/swift-numerics@" + (numerics_version or numerics_revision),
            "externalReferences": [{"type": "vcs", "url": "https://github.com/apple/swift-numerics"}],
            "properties": [{"name": "vauta:revision", "value": numerics_revision}],
        },
        {
            "type": "machine-learning-model",
            "bom-ref": "model:google/embeddinggemma-2",
            "name": "EmbeddingGemma 2 (optional search model, downloaded on request, not bundled)",
            "version": SEARCH_MODEL["revision"],
            "author": "Google",
            "licenses": [{"license": {"id": "Apache-2.0"}}],
            "purl": "pkg:huggingface/google/embeddinggemma-2@" + SEARCH_MODEL["revision"],
            "externalReferences": [{"type": "distribution", "url": "https://huggingface.co/google/embeddinggemma-2"}],
            "hashes": [{"alg": "SHA-256", "content": SEARCH_MODEL["source_sha256"]}],
            "properties": [
                {"name": "vauta:distribution", "value": "not bundled; downloaded from huggingface.co only when the user clicks Download or imports a file"},
                {"name": "vauta:source-file", "value": "model.safetensors"},
                {"name": "vauta:text-tower-assembled-sha256", "value": SEARCH_MODEL["assembled_sha256"]},
                {"name": "vauta:tokenizer-sha256", "value": SEARCH_MODEL["tokenizer_sha256"]},
                {"name": "vauta:modification", "value": "only the 413 language_model tensors are fetched; the weights are unchanged and a new safetensors header addresses the same bytes"},
            ],
        },
    ]
    for framework in system_frameworks():
        components.append({
            "type": "framework",
            "bom-ref": f"apple:{framework}",
            "name": framework,
            "supplier": {"name": "Apple Inc."},
            "description": "Part of macOS; not redistributed with Vauta.",
        })
    refs = [c["bom-ref"] for c in components]
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://github.com/MaquinaTech/Vauta/sbom/{version}")),
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "tools": {"components": [{"type": "application", "name": "scripts/generate-sbom.py", "version": "1"}]},
            "component": {
                "type": "application",
                "bom-ref": app_ref,
                "name": "Vauta",
                "version": version,
                "author": "Nicolás López de Lerma López",
                "licenses": [{"license": {"id": "Apache-2.0"}}],
                "purl": app_ref,
                "externalReferences": [{"type": "vcs", "url": "https://github.com/MaquinaTech/Vauta"}],
            },
        },
        "components": components,
        "dependencies": [{"ref": app_ref, "dependsOn": refs}],
    }
    check_cyclonedx_15(document)
    return document


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--version", required=True, help="release version, e.g. 0.9.0")
    parser.add_argument("--output", required=True, help="file to write")
    parser.add_argument("--timestamp", help="ISO 8601 UTC time (default: now; SOURCE_DATE_EPOCH is honoured)")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", args.version):
        sys.exit("error: version must look like 1.2.3")
    stamp = args.timestamp
    if not stamp:
        import os
        epoch = os.environ.get("SOURCE_DATE_EPOCH")
        moment = datetime.fromtimestamp(int(epoch), timezone.utc) if epoch else datetime.now(timezone.utc)
        stamp = moment.strftime("%Y-%m-%dT%H:%M:%SZ")
    document = build(args.version, stamp)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"OK: {output} ({len(document['components'])} components)")


if __name__ == "__main__":
    main()
