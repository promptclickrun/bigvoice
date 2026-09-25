#!/usr/bin/env python3
"""Install checksum-pinned native libraries for builds, never model weights."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import tarfile
import tempfile
import urllib.request


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def main():
    root = Path(__file__).resolve().parent.parent
    lock_path = root / "Resources/onnx-runtime.lock.json"
    lock = json.loads(lock_path.read_text())
    if platform.machine() != lock["architecture"]:
        raise RuntimeError("This pinned ONNX speech runtime requires Apple Silicon.")
    destination = root / ".build/onnx-runtime"
    destination.mkdir(parents=True, exist_ok=True)
    receipt_path = destination / "installed.json"
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get("lock_sha256") == digest(lock_path):
            libraries = receipt.get("libraries", {})
            expected = {component["library"] for component in lock["components"]}
            if expected.issubset(libraries) and all(
                Path(name).name == name
                and (destination / name).resolve().parent == destination.resolve()
                and (destination / name).is_file()
                and digest(destination / name) == checksum
                for name, checksum in libraries.items()
            ):
                print(f"Verified native ONNX runtime: {destination}")
                return

    hashes = {}
    with tempfile.TemporaryDirectory(prefix="onnx-stage-", dir=destination) as temporary:
        staging = Path(temporary)
        for component in lock["components"]:
            archive = staging / f"{component['name']}.tar.gz"
            print(f"Fetching {component['name']} {component['version']}...")
            request = urllib.request.Request(component["url"], headers={"User-Agent": "bigvoice-build"})
            with urllib.request.urlopen(request, timeout=120) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output, 1024 * 1024)
            if digest(archive) != component["sha256"]:
                raise RuntimeError(f"Checksum mismatch for {component['name']}; nothing was installed.")
            with tarfile.open(archive) as package:
                libraries = [
                    member for member in package.getmembers()
                    if member.isfile()
                    and Path(member.name).name == component["archive_library"]
                    and not any(part.endswith(".dSYM") for part in Path(member.name).parts)
                ]
                if len(libraries) != 1:
                    raise RuntimeError(f"Expected exactly one {component['archive_library']} binary.")
                library = staging / component["library"]
                source = package.extractfile(libraries[0])
                if source is None:
                    raise RuntimeError(f"Could not read {libraries[0].name}.")
                with source, library.open("wb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(library, 0o755)
                hashes[library.name] = digest(library)
                for alias in component["aliases"]:
                    (staging / alias).symlink_to(component["library"])
                    hashes[alias] = hashes[library.name]
                for member in package.getmembers():
                    name = Path(member.name).name
                    if member.isfile() and (
                        name.upper().startswith("LICENSE") or "thirdpartynotice" in name.lower()
                    ):
                        source = package.extractfile(member)
                        if source is None:
                            raise RuntimeError(f"Could not read license notice {member.name}.")
                        notice_name = member.name.split("/", 1)[-1].replace("/", "_")
                        target = staging / f"{component['name']}-{notice_name}"
                        with source, target.open("wb") as output:
                            shutil.copyfileobj(source, output)
            archive.unlink()
        for file in staging.iterdir():
            os.replace(file, destination / file.name)
    receipt_path.write_text(json.dumps({"lock_sha256": digest(lock_path), "libraries": hashes}, indent=2) + "\n")
    print(f"Native ONNX runtime ready: {destination}")


if __name__ == "__main__":
    main()
