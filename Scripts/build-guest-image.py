#!/usr/bin/env python3
"""Build the Linux system that runs inside a Meridian sandbox.

The result is a kernel plus an initramfs. It contains the guest agent and,
when the downloads succeed, Node, Claude Code, Codex and git. No API key is
written into the image.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ALPINE = "https://dl-cdn.alpinelinux.org/alpine/latest-stable"
NODE_INDEX = "https://nodejs.org/dist/index.json"
ROOTS = ["python3", "kmod", "linux-lts", "ca-certificates", "git", "bash", "curl"]


class Package:
    def __init__(self, name, version, installed, depends, provides, repo):
        self.name = name
        self.version = version
        self.installed = installed
        self.depends = depends
        self.provides = provides
        self.repo = repo

    @property
    def filename(self):
        return f"{self.name}-{self.version}.apk"


def curl_bytes(url):
    print(f"download {url}", flush=True)
    return subprocess.check_output(["curl", "-fsSL", "--retry", "3", "--retry-delay", "2", url])


def cached(url, cache):
    digest = hashlib.sha256(url.encode()).hexdigest()[:16]
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", url.rsplit("/", 1)[-1])
    path = cache / f"{digest}-{name}"
    if path.exists() and path.stat().st_size > 0:
        print(f"cache {path.name}", flush=True)
        return path
    tmp = path.with_suffix(path.suffix + ".part")
    print(f"download {url}", flush=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["curl", "-fL", "--retry", "3", "--retry-delay", "2", "-o", str(tmp), url],
        check=True,
    )
    tmp.replace(path)
    return path


def parse_index(blob, repo):
    text = None
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for member in tar.getmembers():
            if member.name == "APKINDEX" or member.name.endswith("/APKINDEX"):
                text = tar.extractfile(member).read().decode("utf-8", "replace")
                break
    if text is None:
        raise SystemExit(f"APKINDEX missing in {repo}")
    packages = []
    for block in text.split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            fields[key] = value
        if "P" not in fields:
            continue
        depends = fields.get("D", "").split()
        provides = fields.get("p", "").split()
        packages.append(Package(
            fields["P"],
            fields.get("V", ""),
            int(fields.get("I", "0") or 0),
            depends,
            provides,
            repo,
        ))
    return packages


def strip_constraint(token):
    token = token.strip()
    if token.startswith("!"):
        return None
    token = re.split(r"[<>=~]", token, maxsplit=1)[0]
    return token or None


def resolve(packages):
    by_name = {}
    providers = {}
    for package in packages:
        by_name.setdefault(package.name, package)
        providers.setdefault(package.name, []).append(package)
        for item in package.provides:
            name = strip_constraint(item)
            if name:
                providers.setdefault(name, []).append(package)

    def choose(token):
        name = strip_constraint(token)
        if not name:
            return None
        if name in by_name:
            return by_name[name]
        options = providers.get(name, [])
        if not options:
            return None
        for option in options:
            if option.name == "linux-firmware-none":
                return option
        return min(options, key=lambda item: item.installed)

    selected = {}
    stack = list(ROOTS)

    def visit(token):
        package = choose(token)
        if package is None:
            print(f"unresolved {token}", flush=True)
            return
        if package.name in selected:
            return
        selected[package.name] = package
        for dep in package.depends:
            visit(dep)

    for root in stack:
        visit(root)
    return list(selected.values())


def extract_apk(path, dest):
    data = path.read_bytes()
    blob = io.BytesIO(data)
    found = False
    while blob.tell() < len(data):
        pos = blob.tell()
        magic = blob.read(2)
        if magic != b"\x1f\x8b":
            rest = magic + blob.read()
            next_magic = rest.find(b"\x1f\x8b")
            if next_magic < 0:
                break
            blob.seek(pos + next_magic)
            continue
        blob.seek(pos)
        try:
            with gzip.GzipFile(fileobj=blob) as gz:
                payload = gz.read()
        except (EOFError, OSError, gzip.BadGzipFile):
            break
        found = True
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as tar:
            tar.extractall(dest, filter=allow_member)
    if not found:
        raise SystemExit(f"{path.name} is not an apk")


def allow_member(member, _path):
    if member.isdev() or member.isfifo():
        return None
    name = member.name
    if name.startswith("/") or ".." in Path(name).parts:
        return None
    return member


def extract_tar(path, dest):
    mode = "r:gz" if str(path).endswith(".gz") else "r:*"
    with tarfile.open(path, mode) as tar:
        tar.extractall(dest, filter=allow_member)


def latest_miniroot(cache):
    html = curl_bytes(ALPINE + "/releases/aarch64/").decode("utf-8", "replace")
    names = sorted(set(re.findall(r"alpine-minirootfs-\d[\d.]*-aarch64\.tar\.gz", html)))
    if not names:
        raise SystemExit("no Alpine minirootfs found")
    name = names[-1]
    return cached(f"{ALPINE}/releases/aarch64/{name}", cache)


def bundle_certificates(root):
    chunks = []
    for folder in [root / "usr/share/ca-certificates", root / "etc/ssl/certs"]:
        if not folder.exists():
            continue
        for path in folder.rglob("*"):
            if path.is_file() and path.suffix == ".crt" and path.name != "ca-certificates.crt":
                chunks.append(path.read_bytes())
    if not chunks:
        return
    certs = root / "etc/ssl/certs"
    certs.mkdir(parents=True, exist_ok=True)
    bundle = certs / "ca-certificates.crt"
    bundle.write_bytes(b"\n".join(chunks) + b"\n")
    link = root / "etc/ssl/cert.pem"
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to("certs/ca-certificates.crt")


def install_node(root, cache):
    payload = curl_bytes(NODE_INDEX)
    releases = json.loads(payload)
    version = next(item["version"] for item in releases if item["version"].startswith("v22."))
    archive = cached(
        f"https://nodejs.org/dist/{version}/node-{version}-linux-arm64.tar.xz",
        cache,
    )
    with tarfile.open(archive, mode="r:xz") as tar:
        tar.extractall(root / "tmp-node", filter=allow_member)
    extracted = next((root / "tmp-node").iterdir())
    target = root / "usr/local"
    target.mkdir(parents=True, exist_ok=True)
    for child in extracted.iterdir():
        dest = target / child.name
        if dest.exists():
            if dest.is_dir() and child.is_dir():
                shutil.copytree(child, dest, dirs_exist_ok=True)
            continue
        shutil.move(str(child), str(dest))
    shutil.rmtree(root / "tmp-node", ignore_errors=True)
    return version


def install_claude(root):
    node_bin = Path("/opt/homebrew/bin")
    npm = node_bin / "npm"
    if not npm.exists():
        found = shutil.which("npm")
        npm = Path(found) if found else npm
    if not npm.exists():
        print("npm missing, skip Claude Code", flush=True)
        return False
    env = os.environ.copy()
    env["PATH"] = str(node_bin) + os.pathsep + env.get("PATH", "")
    command = [
        str(npm), "install", "-g",
        "--prefix", str(root / "usr/local"),
        "--os=linux", "--cpu=arm64", "--libc=musl",
        "@anthropic-ai/claude-code",
    ]
    print("install Claude Code for linux-arm64", flush=True)
    result = subprocess.run(command, env=env)
    if result.returncode != 0:
        print("Claude Code install failed, sandbox can still open a shell", flush=True)
        return False
    dest = root / "usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    natives = list((root / "usr/local/lib/node_modules").glob("**/claude-code-linux-arm64-musl/claude"))
    native = next((path for path in natives if path.is_file()), None)
    if native is not None:
        if dest.exists() or dest.is_symlink():
            dest.unlink()
        shutil.copyfile(native, dest)
        dest.chmod(0o755)
        shutil.rmtree(native.parent, ignore_errors=True)
    return dest.is_file() and dest.stat().st_size > 4096


def install_codex(root, cache):
    try:
        if shutil.which("gh"):
            payload = subprocess.check_output(["gh", "api", "repos/openai/codex/releases/latest"])
        else:
            payload = subprocess.check_output([
                "curl", "-fsSL", "--retry", "3",
                "-H", "User-Agent: meridian-image",
                "-H", "Accept: application/vnd.github+json",
                "https://api.github.com/repos/openai/codex/releases/latest",
            ])
        release = json.loads(payload)
    except Exception as error:
        print(f"skip Codex ({error})", flush=True)
        return False
    asset = None
    for item in release.get("assets", []):
        if item["name"] == "codex-aarch64-unknown-linux-musl.tar.gz":
            asset = item
            break
    if asset is None:
        print("Codex linux-arm64 archive not found", flush=True)
        return False
    archive = cached(asset["browser_download_url"], cache)
    with tarfile.open(archive, mode="r:gz") as tar:
        members = [item for item in tar.getmembers() if item.isfile()]
        member = next((item for item in members if Path(item.name).name == "codex"), None)
        if member is None and len(members) == 1:
            member = members[0]
        if member is None:
            print("Codex binary missing in archive", flush=True)
            return False
        dest = root / "usr/local/bin/codex"
        dest.parent.mkdir(parents=True, exist_ok=True)
        source = tar.extractfile(member)
        dest.write_bytes(source.read())
        dest.chmod(0o755)
    return True


def arm64_image(data):
    return len(data) > 0x40 and data[0x38:0x3C] == b"ARM\x64"


def first_gzip_payload(data):
    source = io.BytesIO(data)
    output = bytearray()
    try:
        with gzip.GzipFile(fileobj=source) as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                output += chunk
    except gzip.BadGzipFile:
        if not output:
            raise
    return bytes(output)


def kernel_from(root, output):
    boot = root / "boot"
    boots = list(boot.glob("vmlinuz*")) if boot.exists() else []
    if not boots:
        raise SystemExit("linux-lts did not contain a kernel")
    kernel = boots[0].resolve()
    data = kernel.read_bytes()
    kind = "unknown"
    if data.startswith(b"MZ"):
        gzip_at = data.find(b"\x1f\x8b")
        if gzip_at > 0:
            data = data[gzip_at:]
            kind = "gzip-inside-pe"
    if data.startswith(b"\x1f\x8b"):
        unpacked = first_gzip_payload(data)
        if arm64_image(unpacked):
            data = unpacked
            kind = "arm64-image"
        else:
            kind = "gzip"
    elif arm64_image(data):
        kind = "arm64-image"
    if not arm64_image(data) and not data.startswith(b"\x1f\x8b"):
        raise SystemExit(f"kernel {kernel.name} is not an ARM64 image Virtualization can boot")
    print(f"kernel {kernel.name} {kind} {len(data)} bytes", flush=True)
    dest = output / "kernel"
    dest.write_bytes(data)
    shutil.rmtree(root / "boot", ignore_errors=True)
    return dest


def pack_initramfs(root, dest):
    print("pack initramfs", flush=True)
    find = subprocess.Popen(["find", ".", "-print0"], cwd=root, stdout=subprocess.PIPE)
    cpio = subprocess.Popen(
        ["cpio", "--null", "-o", "--format", "newc"],
        cwd=root,
        stdin=find.stdout,
        stdout=subprocess.PIPE,
    )
    find.stdout.close()
    with gzip.open(dest, "wb", compresslevel=1) as handle:
        shutil.copyfileobj(cpio.stdout, handle)
    if cpio.wait() != 0 or find.wait() != 0:
        raise SystemExit("failed to pack initramfs")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--init", required=True)
    args = parser.parse_args()
    output = Path(args.output).expanduser()
    cache = output / "cache"
    output.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    staging = output.parent / (output.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    try:
        with tempfile.TemporaryDirectory(prefix="meridian-root-") as tmp:
            root = Path(tmp)
            print("extract minirootfs", flush=True)
            extract_tar(latest_miniroot(cache), root)
            indexes = []
            for repo in ("main", "community"):
                blob = cached(f"{ALPINE}/{repo}/aarch64/APKINDEX.tar.gz", cache).read_bytes()
                indexes.extend(parse_index(blob, f"{ALPINE}/{repo}/aarch64"))
            chosen = resolve(indexes)
            print(f"packages {len(chosen)}", flush=True)
            for package in chosen:
                apk = cached(f"{package.repo}/{package.filename}", cache)
                extract_apk(apk, root)
            kernel_from(root, staging)
            node = install_node(root, cache)
            has_claude = install_claude(root)
            has_codex = install_codex(root, cache)
            bundle_certificates(root)
            agent = root / "usr/local/bin/meridian-agent"
            agent.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.agent, agent)
            agent.chmod(0o755)
            init = root / "init"
            shutil.copyfile(args.init, init)
            init.chmod(0o755)
            (root / "etc/hostname").write_text("meridian\n")
            (root / "etc/hosts").write_text("127.0.0.1 localhost\n")
            resolv = root / "etc/resolv.conf"
            resolv.write_text("nameserver 127.0.0.1\n")
            pack_initramfs(root, staging / "initramfs.img")

        manifest = {
            "hasClaude": has_claude,
            "hasCodex": has_codex,
            "hasNode": True,
            "hasGit": True,
            "builtAt": datetime.now(timezone.utc).isoformat(),
            "kernelName": "kernel",
            "initramfsName": "initramfs.img",
            "note": f"Alpine latest-stable, Node {node}",
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for name in ("kernel", "initramfs.img", "manifest.json"):
            src = staging / name
            dest = output / name
            tmp = output / (name + ".new")
            shutil.copy2(src, tmp)
            tmp.replace(dest)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    print(f"image ready at {output}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(1)
