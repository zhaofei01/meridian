#!/usr/bin/python3
"""Guest side of Meridian.

The virtual machine has no network interface. This process is the only door:
local programs talk to 127.0.0.1, and this process carries the bytes to the
Mac over a virtio socket. It never sees a real API key or password.
"""

import errno
import json
import os
import pty
import queue
import select
import shutil
import signal
import socket
import struct
import subprocess
import threading
import time

HOST_CID = 2
HOST_PORT = 5000
FLAG_OPEN = 1
FLAG_DATA = 2
FLAG_CLOSE = 4
FLAG_HELLO = 8
FLAG_RESIZE = 16
ALLOWED = {"claude", "codex", "bash", "sh"}
WORKSPACE = "/workspace"


def under_workspace(path):
    try:
        real = os.path.realpath(path)
        root = os.path.realpath(WORKSPACE)
        return real == root or real.startswith(root + os.sep)
    except OSError:
        return False


def pack_frame(stream_id, flags, payload):
    return struct.pack(">IHI", stream_id, flags, len(payload)) + payload


def _selftest():
    assert pack_frame(1, FLAG_DATA, b"hi") == bytes.fromhex("000000010002000000026869")


class Mux:
    def __init__(self, sock):
        self.sock = sock
        self.lock = threading.Lock()
        self.streams = {}
        self.next_id = 1
        self.shell = None
        self.ready = threading.Event()
        self.github = False

    def send(self, stream_id, flags, payload):
        frame = pack_frame(stream_id, flags, payload)
        with self.lock:
            self.sock.sendall(frame)

    def open_stream(self, description):
        with self.lock:
            stream_id = self.next_id
            self.next_id += 2
        stream = Stream(self, stream_id)
        self.streams[stream_id] = stream
        self.send(stream_id, FLAG_OPEN, json.dumps(description).encode())
        return stream

    def open_tcp(self, host, port):
        stream = self.open_stream({"kind": "tcp", "host": host, "port": int(port)})
        kind, payload = stream.wait()
        if kind != "open":
            text = payload.decode("utf-8", "replace")
            raise PermissionError(text or "denied")
        return stream

    def loop(self):
        try:
            while True:
                stream_id, flags, payload = read_frame(self.sock)
                self.dispatch(stream_id, flags, payload)
        except (OSError, EOFError):
            print("meridian: host channel closed", flush=True)
            os._exit(0)

    def dispatch(self, stream_id, flags, payload):
        if flags & FLAG_HELLO:
            info = json.loads(payload.decode() or "{}")
            if not self.ready.is_set():
                self.github = bool(info.get("github"))
                configure_guest(self.github)
                self.ready.set()
                mounted = os.environ.get("MERIDIAN_WORKSPACE_MOUNTED") == "1"
                reply = {
                    "kind": "hello",
                    "role": "guest",
                    "version": 1,
                    "workspace": mounted,
                    "ready": True,
                    "github": self.github,
                }
                self.send(0, FLAG_HELLO, json.dumps(reply).encode())
            return
        if flags & FLAG_OPEN and stream_id % 2 == 0 and stream_id not in self.streams:
            threading.Thread(target=self.spawn_shell, args=(stream_id, payload), daemon=True).start()
            return
        stream = self.streams.get(stream_id)
        if stream is None:
            return
        if flags & FLAG_DATA:
            stream.events.put(("data", payload))
        if flags & FLAG_OPEN:
            stream.events.put(("open", payload))
        if flags & FLAG_RESIZE:
            stream.events.put(("resize", payload))
        if flags & FLAG_CLOSE:
            stream.events.put(("close", payload))

    def spawn_shell(self, stream_id, payload):
        if self.shell is not None:
            self.shell.stop()
        info = json.loads(payload.decode() or "{}")
        shell = Shell(self, stream_id, info)
        self.shell = shell
        self.streams[stream_id] = shell.stream
        shell.run()


class Stream:
    def __init__(self, mux, stream_id):
        self.mux = mux
        self.stream_id = stream_id
        self.events = queue.Queue()

    def send(self, data):
        if data:
            self.mux.send(self.stream_id, FLAG_DATA, data)

    def close(self, payload=b""):
        self.mux.send(self.stream_id, FLAG_CLOSE, payload)

    def wait(self):
        return self.events.get()


class Shell:
    def __init__(self, mux, stream_id, info):
        self.mux = mux
        self.stream = Stream(mux, stream_id)
        self.info = info
        self.proc = None
        self.master = None
        self.stopped = False

    def stop(self):
        self.stopped = True
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGHUP)
            except OSError:
                pass

    def run(self):
        argv = resolve_argv(self.info.get("argv") or ["bash"])
        cwd = self.info.get("cwd") or "/workspace"
        if not under_workspace(cwd):
            cwd = "/workspace"
        if not os.path.isdir(cwd):
            cwd = "/"
        cols = int(self.info.get("cols") or 100)
        rows = int(self.info.get("rows") or 32)
        if argv is None:
            self.stream.send("这个工作室不能运行这个程序。\r\n".encode())
            self.stream.close(json.dumps({"code": 127}).encode())
            return
        master, slave = pty.openpty()
        set_size(slave, cols, rows)
        env = guest_env()
        try:
            self.proc = subprocess.Popen(
                argv,
                stdin=slave,
                stdout=slave,
                stderr=slave,
                cwd=cwd,
                env=env,
                preexec_fn=os.setsid,
            )
        except OSError as error:
            os.close(slave)
            os.close(master)
            self.stream.send(f"没有启动起来：{error}\r\n".encode())
            self.stream.close(json.dumps({"code": 127}).encode())
            return
        os.close(slave)
        self.master = master
        if os.path.basename(argv[0]) in {"bash", "sh"} and not shutil.which("claude"):
            note = "这间沙箱里还没有 Claude Code。可以先用终端；准备沙箱系统完成后再打开它。\r\n"
            os.write(master, note.encode())
        threading.Thread(target=self.pump_out, daemon=True).start()
        self.pump_in()

    def pump_out(self):
        while not self.stopped:
            try:
                ready, _, _ = select.select([self.master], [], [], 0.5)
            except (OSError, ValueError):
                break
            if not ready:
                if self.proc and self.proc.poll() is not None:
                    break
                continue
            try:
                data = os.read(self.master, 65536)
            except OSError:
                break
            if not data:
                break
            self.stream.send(data)
        code = self.proc.wait() if self.proc else 0
        self.stream.close(json.dumps({"code": code}).encode())
        if self.master is not None:
            os.close(self.master)
            self.master = None

    def pump_in(self):
        while not self.stopped:
            kind, payload = self.stream.wait()
            if kind == "data" and self.master is not None:
                try:
                    os.write(self.master, payload)
                except OSError:
                    break
            elif kind == "resize" and self.master is not None:
                try:
                    info = json.loads(payload.decode() or "{}")
                    set_size(self.master, int(info.get("cols") or 80), int(info.get("rows") or 24))
                    if self.proc:
                        os.killpg(self.proc.pid, signal.SIGWINCH)
                except (OSError, ValueError):
                    pass
            elif kind == "close":
                self.stop()
                break


def resolve_argv(argv):
    if not argv:
        return None
    base = os.path.basename(argv[0])
    if base not in ALLOWED:
        return None
    if base in {"bash", "sh"}:
        shell = "/bin/bash" if os.path.exists("/bin/bash") else "/bin/sh"
        return [shell] + argv[1:]
    path = shutil.which(base)
    if not path:
        return None
    return [path] + argv[1:]


def set_size(fd, cols, rows):
    import fcntl
    import termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def guest_env():
    env = os.environ.copy()
    env.update({
        "HOME": "/root",
        "TERM": "xterm-256color",
        "LANG": "C.UTF-8",
        "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
        "ANTHROPIC_API_KEY": "meridian-local",
        "OPENAI_BASE_URL": "http://127.0.0.1:8788/v1",
        "OPENAI_API_KEY": "meridian-local",
        "HTTP_PROXY": "http://127.0.0.1:8888",
        "HTTPS_PROXY": "http://127.0.0.1:8888",
        "http_proxy": "http://127.0.0.1:8888",
        "https_proxy": "http://127.0.0.1:8888",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
        "GIT_TERMINAL_PROMPT": "0",
        "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt",
    })
    return env


def configure_guest(github):
    os.makedirs("/root", exist_ok=True)
    write_claude_config(github)
    if github:
        write_git_config()
    write_npm_config()


def write_claude_config(github):
    os.makedirs("/root/.claude", exist_ok=True)
    servers = {}
    if github:
        servers["github"] = {"type": "http", "url": "http://127.0.0.1:8790/mcp"}
    path = "/root/.claude.json"
    existing = {}
    if os.path.exists(path):
        try:
            with open(path) as handle:
                existing = json.load(handle)
        except (OSError, ValueError):
            existing = {}
    existing["mcpServers"] = servers
    with open(path, "w") as handle:
        json.dump(existing, handle)


def write_git_config():
    git = shutil.which("git")
    if not git:
        return
    commands = [
        ["config", "--global", "url.http://127.0.0.1:8791/github/.insteadOf", "https://github.com/"],
        ["config", "--global", "url.http://127.0.0.1:8791/github/.insteadOf", "git@github.com:"],
        ["config", "--global", "url.http://127.0.0.1:8791/github/.insteadOf", "ssh://git@github.com/"],
        ["config", "--global", "http.proxy", "http://127.0.0.1:8888"],
        ["config", "--global", "https.proxy", "http://127.0.0.1:8888"],
        ["config", "--global", "http.http://127.0.0.1.proxy", ""],
    ]
    env = guest_env()
    for args in commands:
        subprocess.run([git, *args], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def write_npm_config():
    os.makedirs("/root", exist_ok=True)
    with open("/root/.npmrc", "w") as handle:
        handle.write("\n".join([
            "proxy=http://127.0.0.1:8888",
            "https-proxy=http://127.0.0.1:8888",
            "noproxy=127.0.0.1,localhost",
            "",
        ]))


def serve_tcp(port, handler):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(64)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=handler, args=(conn,), daemon=True).start()


def splice_stream(conn, stream, initial=b""):
    if initial:
        stream.send(initial)

    def inbound():
        try:
            while True:
                data = conn.recv(65536)
                if not data:
                    break
                stream.send(data)
        except OSError:
            pass
        finally:
            stream.close()

    threading.Thread(target=inbound, daemon=True).start()
    try:
        while True:
            kind, payload = stream.wait()
            if kind == "data":
                conn.sendall(payload)
            elif kind == "close":
                break
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def handle_service(mux, conn, name):
    try:
        stream = mux.open_stream({"kind": "service", "name": name})
        splice_stream(conn, stream)
    except OSError:
        conn.close()


def handle_proxy(mux, conn):
    try:
        header, rest = read_http_head(conn)
    except (OSError, ValueError):
        conn.close()
        return
    if header is None:
        conn.close()
        return
    line = header.split("\r\n", 1)[0]
    parts = line.split(" ")
    if len(parts) < 2:
        conn.close()
        return
    method, target = parts[0], parts[1]
    try:
        if method == "CONNECT":
            host, port = split_host_port(target, 443)
            if is_local(host):
                reply_local_connect(conn, host, port, rest)
                return
            stream = mux.open_tcp(host, port)
            conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            splice_stream(conn, stream, rest)
            return
        host, port, rewritten = absolute_request(method, target, header, rest)
        if host is None:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            conn.close()
            return
        if is_local(host):
            reply_local_connect(conn, host, port, rewritten, raw=True)
            return
        stream = mux.open_tcp(host, port)
        splice_stream(conn, stream, rewritten)
    except PermissionError:
        conn.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        conn.close()
    except OSError:
        conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        conn.close()


def is_local(host):
    return host in {"127.0.0.1", "localhost", "::1"}


def split_host_port(target, default):
    if target.startswith("["):
        host, _, port = target[1:].partition("]")
        port = port[1:] if port.startswith(":") else str(default)
        return host, int(port)
    if target.count(":") == 1:
        host, port = target.split(":")
        return host, int(port)
    return target, default


def read_http_head(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None, b""
        data += chunk
        if len(data) > 65536:
            raise ValueError("header too large")
    head, rest = data.split(b"\r\n\r\n", 1)
    return head.decode("iso-8859-1", "replace"), rest


def absolute_request(method, target, header, rest):
    if not target.startswith("http://") and not target.startswith("https://"):
        return None, None, b""
    scheme, _, remainder = target.partition("://")
    hostport, _, path = remainder.partition("/")
    host, port = split_host_port(hostport, 443 if scheme == "https" else 80)
    path = "/" + path
    lines = header.split("\r\n")
    lines[0] = f"{method} {path} HTTP/1.1"
    rebuilt = "\r\n".join(lines).encode("iso-8859-1", "replace") + b"\r\n\r\n" + rest
    return host, port, rebuilt


def reply_local_connect(conn, host, port, rest, raw=False):
    remote = socket.create_connection((host, port))
    if not raw:
        conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    if rest:
        remote.sendall(rest)

    def pump(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    threading.Thread(target=pump, args=(conn, remote), daemon=True).start()
    pump(remote, conn)
    conn.close()
    remote.close()


def read_exact(sock, count):
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def read_frame(sock):
    header = read_exact(sock, 10)
    stream_id, flags, length = struct.unpack(">IHI", header)
    if length > 8 * 1024 * 1024:
        raise OSError(errno.E2BIG, "frame")
    payload = read_exact(sock, length) if length else b""
    return stream_id, flags, payload


def connect_host():
    while True:
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.connect((HOST_CID, HOST_PORT))
            return sock
        except OSError as error:
            print(f"meridian: waiting for host ({error})", flush=True)
            time.sleep(0.3)


def main():
    if os.environ.get("MERIDIAN_SELFTEST") == "1":
        _selftest()
        print("ok")
        return
    mounted = os.environ.get("MERIDIAN_WORKSPACE_MOUNTED") == "1"
    print(f"meridian: agent starting, workspace={mounted}", flush=True)
    sock = connect_host()
    mux = Mux(sock)
    threading.Thread(target=mux.loop, daemon=True).start()
    hello = {
        "kind": "hello",
        "role": "guest",
        "version": 1,
        "workspace": mounted,
        "ready": False,
    }
    listeners = [
        (8787, lambda conn: handle_service(mux, conn, "anthropic")),
        (8788, lambda conn: handle_service(mux, conn, "openai")),
        (8790, lambda conn: handle_service(mux, conn, "github-mcp")),
        (8791, lambda conn: handle_service(mux, conn, "github-git")),
        (8888, lambda conn: handle_proxy(mux, conn)),
    ]
    for port, handler in listeners:
        threading.Thread(target=serve_tcp, args=(port, handler), daemon=True).start()
    time.sleep(0.05)
    mux.send(0, FLAG_HELLO, json.dumps(hello).encode())
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
