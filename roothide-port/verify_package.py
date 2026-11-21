#!/usr/bin/env python3
"""Read-only structural verification of a Dopamine-roothide candidate deb."""
import argparse
import hashlib
import io
import json
import pathlib
import plistlib
import struct
import subprocess
import tarfile

BASE_ENTITLEMENTS = (
    "platform-application",
    "com.apple.private.security.no-sandbox",
    "com.apple.private.security.storage.AppBundles",
    "com.apple.private.security.storage.AppDataContainers",
)
EXECUTABLES = (
    "Applications/DSH.app/DSHNativeApp",
    "Applications/DSH.app/DSHLauncher",
    "usr/bin/dsh-app-helper",
    "usr/bin/mcp-logreader",
    "usr/lib/dsh/bin/node",
    "usr/lib/dsh/bin/node-real",
)
INJECTED = (
    "Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.dylib",
    "Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.dylib",
)


def deb_members(path):
    data = path.read_bytes()
    if data[:8] != b"!<arch>\n":
        raise ValueError("Not a Debian ar archive")
    result, offset = {}, 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b"`\n":
            raise ValueError("Invalid ar member header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58])
        if offset + 60 + size > len(data) or name in result:
            raise ValueError("Truncated or duplicated ar member")
        result[name] = data[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
    return result


def tar_members(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        items = {}
        for item in archive:
            name = item.name.removeprefix("./").rstrip("/")
            if name in ("", "."):
                continue
            path = pathlib.PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or name in items:
                raise ValueError("Unsafe or duplicate tar path: " + name)
            items[name] = (item, archive.extractfile(item).read() if item.isfile() else None)
        return items


def version(value):
    return (value >> 16, (value >> 8) & 255, value & 255)


def macho(data):
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = data[:4] == b"\xca\xfe\xba\xbf"
        count = struct.unpack_from(">I", data, 4)[0]
        if count > 32:
            raise ValueError("Invalid fat Mach-O slice count")
        result = []
        for i in range(count):
            entry = 8 + i * (32 if wide else 20)
            offset, size = struct.unpack_from(">QQ" if wide else ">II", data, entry + 8)
            if offset + size > len(data):
                raise ValueError("Mach-O slice exceeds file")
            result.extend(macho(data[offset:offset + size]))
        return result
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a 64-bit little-endian Mach-O")
    cpu, subtype = struct.unpack_from("<II", data, 4)
    count = struct.unpack_from("<I", data, 16)[0]
    offset, result = 32, {
        "cpu": cpu, "subtype": subtype, "dependencies": [],
        "signed_blob": False, "entitlements": {},
    }
    if count > 4096:
        raise ValueError("Invalid Mach-O command count")
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command == 0x32:
            platform, minimum, sdk = struct.unpack_from("<III", data, offset + 8)
            result.update(platform=platform, minimum_os=version(minimum), sdk=version(sdk))
        elif command == 0x24:
            minimum, sdk = struct.unpack_from("<II", data, offset + 8)
            result.update(platform=2, minimum_os=version(minimum), sdk=version(sdk))
        elif command in (0xC, 0x80000018, 0x8000001F):
            start = struct.unpack_from("<I", data, offset + 8)[0]
            name = data[offset + start:offset + size].split(b"\0", 1)[0].decode("utf-8", "replace")
            result["dependencies"].append(name)
        elif command == 0x1D:
            start, length = struct.unpack_from("<II", data, offset + 8)
            sig = data[start:start + length]
            result["signed_blob"] = bool(sig)
            if len(sig) >= 12 and struct.unpack_from(">I", sig)[0] == 0xFADE0CC0:
                slots = struct.unpack_from(">I", sig, 8)[0]
                for i in range(slots):
                    slot, position = struct.unpack_from(">II", sig, 12 + i * 8)
                    if position + 8 > len(sig):
                        raise ValueError("Invalid signature slot")
                    magic, blob_size = struct.unpack_from(">II", sig, position)
                    if slot == 5 and magic == 0xFADE7171:
                        result["entitlements"] = plistlib.loads(sig[position + 8:position + blob_size])
        elif command == 0x19:
            # Keep a digest of executable instructions independent of re-signing.
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            for i in range(nsects):
                section = offset + 72 + i * 80
                name = data[section:section + 16].split(b"\0", 1)[0]
                segment = data[section + 16:section + 32].split(b"\0", 1)[0]
                if name == b"__text" and segment == b"__TEXT":
                    length = struct.unpack_from("<Q", data, section + 40)[0]
                    start = struct.unpack_from("<I", data, section + 48)[0]
                    result["text_sha256"] = hashlib.sha256(data[start:start + length]).hexdigest()
        offset += size
    return [result]


def inspect(package, original=None):
    errors, report = [], {"file": package.name, "sha256": hashlib.sha256(package.read_bytes()).hexdigest(), "device_tested": False}
    parts = deb_members(package)
    control = tar_members(parts[next(k for k in parts if k.startswith("control.tar"))])
    payload = tar_members(parts[next(k for k in parts if k.startswith("data.tar"))])
    text = control["control"][1].decode("utf-8")
    fields = dict(line.split(":", 1) for line in text.splitlines() if line and not line[0].isspace() and ":" in line)
    fields = {k: v.strip() for k, v in fields.items()}
    report["control"] = fields
    if fields.get("Architecture") != "iphoneos-arm64e":
        errors.append("Package does not use roothide's iphoneos-arm64e architecture")
    if fields.get("Package") != "dev.airdevs.dsh":
        errors.append("Unexpected Debian package identity")
    if any(n == "var/jb" or n.startswith("var/jb/") for n in payload):
        errors.append("Rootless /var/jb wrapper remains in payload")
    nonroot = [name for name, (member, _) in payload.items() if member.uid != 0 or member.gid != 0]
    if nonroot:
        errors.append("Payload ownership is not root:wheel: " + ", ".join(nonroot[:5]))
    for name, (member, _) in payload.items():
        if (member.issym() or member.islnk()) and "/var/jb" in member.linkname:
            errors.append("Rootless symlink remains: " + name)
    required = EXECUTABLES + INJECTED + (
        "usr/lib/dsh/roothide-node-preload.cjs",
        "usr/lib/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js",
        "usr/lib/dsh/libexec/pnpm/bin/pnpm.cjs",
        "Library/LaunchDaemons/dev.airdevs.dsh.plist",
        "Applications/DSH.app/Info.plist",
    )
    for name in required:
        if name not in payload:
            errors.append("Missing required payload: " + name)
    binaries = {}
    for name in EXECUTABLES + INJECTED:
        if name not in payload:
            continue
        member, data = payload[name]
        try:
            slices = macho(data)
            binaries[name] = slices
            for item in slices:
                if item["cpu"] != 0x100000C or item.get("platform") != 2:
                    errors.append("Unexpected CPU or platform: " + name)
                if item.get("minimum_os", (999,)) > (16, 6, 1):
                    errors.append("Binary minimum OS exceeds iOS 16.6.1: " + name)
                if any(d.startswith("/var/jb/") for d in item["dependencies"]):
                    errors.append("Rootless Mach-O dependency remains: " + name)
                newer_runtime = ("/Symbols.framework/", "/AlarmKit.framework/", "libswiftObservation.dylib")
                if any(marker in dependency for marker in newer_runtime for dependency in item["dependencies"]):
                    errors.append("Post-iOS-16 framework/runtime dependency found: " + name)
                if not item["signed_blob"]:
                    errors.append("Missing ad-hoc signature blob: " + name)
                if name in EXECUTABLES:
                    missing = [k for k in BASE_ENTITLEMENTS if item["entitlements"].get(k) is not True]
                    if missing:
                        errors.append("Missing roothide executable entitlements: " + name + ": " + ", ".join(missing))
            if name in INJECTED and not any((s["subtype"] & 0xFFFFFF) == 2 for s in slices):
                errors.append("Missing arm64e injection slice: " + name)
            if name == "usr/bin/dsh-app-helper":
                if member.mode & 0o4000 == 0:
                    errors.append("Privileged helper is missing its setuid bit")
                if member.uid != 0 or member.gid != 0:
                    errors.append("Privileged helper is not owned by root:wheel in the archive")
        except (ValueError, struct.error, plistlib.InvalidFileException) as error:
            errors.append(name + ": " + str(error))
    report["binaries"] = binaries
    if original and "usr/lib/dsh/bin/node-real" in binaries:
        old = deb_members(original)
        old_payload = tar_members(old[next(k for k in old if k.startswith("data.tar"))])
        original_slices = macho(old_payload["var/jb/usr/lib/dsh/bin/node"][1])
        ported_slices = binaries["usr/lib/dsh/bin/node-real"]
        if [s.get("text_sha256") for s in original_slices] != [s.get("text_sha256") for s in ported_slices]:
            errors.append("Upstream Node executable instructions changed")
        for before, after in zip(original_slices, ported_slices):
            for key, value in before["entitlements"].items():
                if after["entitlements"].get(key) != value:
                    errors.append("Node entitlement was lost or changed: " + key)
        report["node_original_text_and_entitlements_preserved"] = not any("Node" in e for e in errors)
    report["errors"] = errors
    report["static_checks_passed"] = not errors
    report["not_verified"] = ["installation on iOS 16.6.1", "engine and plugin runtime", "launchd behavior", "SpringBoard ABI and injection", "re-jailbreak path changes", "cryptographic signature validation on device"]
    try:
        report["port_commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        report["port_commit"] = None
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=pathlib.Path)
    parser.add_argument("--original", type=pathlib.Path)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    report = inspect(args.package, args.original)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"package": args.package.name, "checks_passed": report["static_checks_passed"], "errors": report["errors"], "report": str(args.report)}, ensure_ascii=False))
    return 0 if report["static_checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
