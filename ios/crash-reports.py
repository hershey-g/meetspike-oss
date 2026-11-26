#!/usr/bin/env python3
"""Read the crash and diagnostic reports the Meetspike iPhone app sends to its own Worker.

    python3 ios/crash-reports.py                 # newest first, 20 of them
    python3 ios/crash-reports.py --limit 100
    python3 ios/crash-reports.py --show <id>     # one report, frames symbolicated

The Worker's admin secret and the Cloudflare Access service token come from 1Password
(Shared vault) at the moment of the request, the same way ios/release-testflight.py gets
them. They are never printed. Everything the Worker sends back is treated as untrusted
text: control characters are stripped before anything is printed.

Symbolication: frames of the binary MeetspikeHR are looked up with `atos` in the dSYM that
ios/release-testflight.py kept under ~/Library/Application Support/Meetspike/dSYMs/<build>/.
The dSYM is picked by UUID (`dwarfdump --uuid`), never by build number alone.

How a frame becomes an `atos` call (checked against the build 1 archive's dSYM and against
local arm64 and arm64e builds, see the notes below):
  - MetricKit gives each frame `address` (where the frame was in the process) and
    `offsetIntoBinaryTextSegment` (how far into the binary's __TEXT segment).
  - __TEXT starts at the Mach-O header, so the binary's load address (what `atos -l` wants)
    is `address - offset`. All frames of one binary share it, ASLR slide included.
    `atos -l <load> <address>` then gives the symbol.
  - Passing the frame address as -l, or load + something else, does not fail: atos just
    prints the bare hex address back. That is why an answer that starts with 0x is shown as
    "not symbolicated" and never as a symbol.
  - If `address` is missing or does not fit (address < offset, or the load address is not
    page aligned), the static route is used instead: -l is the dSYM's own __TEXT vmaddr
    (0x100000000 for an iOS app) and the address is vmaddr + offset. Same answer.
  - `-arch` must match the dSYM slice: an arm64e dSYM refuses `-arch arm64`, while an arm64
    dSYM accepts either. So the arch is read from `dwarfdump --uuid` for that UUID, not from
    the report's platformArchitecture.
"""
import argparse, json, os, re, subprocess, sys, time, unicodedata
import urllib.error, urllib.parse, urllib.request
from pathlib import Path

# 1Password ids come from the environment (set them to your own vault and items).
_OP_ENV = {
    "VAULT": "MEETSPIKE_OP_VAULT",
    "ASC_KEY_DOC": "MEETSPIKE_OP_ASC_KEY_DOC",
    "INGEST_ITEM": "MEETSPIKE_OP_INGEST_ITEM",
    "ACCESS_ITEM": "MEETSPIKE_OP_ACCESS_ITEM",
}


def _op_id(name):
    import os, sys
    var = _OP_ENV[name]
    value = os.environ.get(var, "").strip()
    if not value:
        sys.exit(f"{var} is not set. Set it to the 1Password id for {name} before running this script.")
    return value

WORKER = os.environ.get("MEETSPIKE_ORIGIN", "").rstrip("/")
ENDPOINT = "/api/whoop-web/app/diagnostics"
# Cloudflare blocks urllib's default "Python-urllib/3.x" agent (error 1010).
USER_AGENT = "meetspike-tools/1"
# Same folder ios/release-testflight.py keeps the dSYMs in.
DSYM_HOME = Path(os.environ.get("MEETSPIKE_DSYM_DIR")
                 or Path.home() / "Library/Application Support/Meetspike/dSYMs")
APP_BINARY = "MeetspikeHR"
DEFAULT_LIMIT = 20
MAX_LIMIT = 200  # the Worker's own cap
MAX_REPLY_BYTES = 8 * 1024 * 1024
ATOS_TIMEOUT = 60
DEFAULT_TEXT_VMADDR = 0x100000000
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
DWARF_UUID_LINE = re.compile(r"^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) (.+)$")


# ---- plain helpers (no I/O) -------------------------------------------------------------

def clean(value, limit: int = 500) -> str:
    """Printable, one-line text. Control, format and unassigned characters (escape codes,
    bidi overrides) are replaced, so nothing the Worker returned can drive the terminal."""
    text = value if isinstance(value, str) else str(value)
    out = []
    for char in text[:limit]:
        if char in "\n\r\t":
            out.append(" ")
        elif unicodedata.category(char).startswith("C"):
            out.append("?")
        else:
            out.append(char)
    return "".join(out)


def valid_id(text: str) -> str | None:
    text = text.strip().lower()
    return text if UUID_RE.fullmatch(text) else None


def as_int(value) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def load_and_address(frame: dict, text_vmaddr: int) -> tuple[int, int] | None:
    """(load address, address) to hand to `atos -l <load> <address>`, or None if the frame has
    no offset to go on. See the module comment for why load = address - offset."""
    offset = as_int(frame.get("offsetIntoBinaryTextSegment"))
    if offset is None or offset < 0:
        return None
    address = as_int(frame.get("address"))
    if address is not None and address >= offset:
        load = address - offset
        if load > 0 and load % 0x1000 == 0:
            return load, address
    return text_vmaddr, text_vmaddr + offset


def parse_dwarfdump_uuids(output: str) -> list[tuple[str, str, Path]]:
    """(UUID upper case, arch, path of the DWARF file) for each line of `dwarfdump --uuid`."""
    found = []
    for line in output.splitlines():
        match = DWARF_UUID_LINE.match(line.strip())
        if match:
            found.append((match.group(1).upper(), match.group(2), Path(match.group(3))))
    return found


def parse_text_vmaddr(otool_output: str) -> int | None:
    """vmaddr of the __TEXT segment from `otool -l`."""
    lines = otool_output.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "segname __TEXT":
            for follow in lines[index + 1:index + 3]:
                parts = follow.split()
                if len(parts) == 2 and parts[0] == "vmaddr":
                    try:
                        return int(parts[1], 16)
                    except ValueError:
                        return None
    return None


def atos_resolved(line: str) -> bool:
    """atos echoes the bare address when it has no symbol for it."""
    line = line.strip()
    return bool(line) and not line.startswith("0x")


def walk_frames(report) -> list[list[tuple[int, dict]]]:
    """Per call stack, its frames as (depth, frame) in depth first order. Handles
    callStackRootFrames as a list (current MetricKit) or as one frame (older). Iterative,
    so a deep stack cannot hit the recursion limit."""
    tree = report.get("callStackTree") if isinstance(report, dict) else None
    stacks = tree.get("callStacks") if isinstance(tree, dict) else None
    out = []
    for stack in stacks if isinstance(stacks, list) else []:
        if not isinstance(stack, dict):
            continue
        roots = stack.get("callStackRootFrames")
        pending = [(0, f) for f in reversed(roots if isinstance(roots, list) else [roots])]
        frames = []
        while pending and len(frames) < 20000:
            depth, frame = pending.pop()
            if not isinstance(frame, dict):
                continue
            frames.append((depth, frame))
            subs = frame.get("subFrames")
            if isinstance(subs, list):
                pending.extend((depth + 1, f) for f in reversed(subs))
        out.append((stack.get("threadAttributed") is True, frames))
    return out


# ---- the dSYM side ----------------------------------------------------------------------

def run_tool(args: list[str]) -> str | None:
    """Run a developer tool (no shell). None if it is missing, fails or times out."""
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=ATOS_TIMEOUT, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


class DsymIndex:
    """The kept dSYMs, looked up by binary UUID. The folder for the report's build is read
    first, then the others, so an old report still finds the dSYM of an older build."""

    def __init__(self, root: Path):
        self.root = root
        self.by_uuid: dict[str, tuple[str, Path]] = {}
        self.scanned: set[Path] = set()
        self.vmaddr: dict[Path, int] = {}

    def _scan(self, folder: Path) -> None:
        if folder in self.scanned or not folder.is_dir():
            return
        self.scanned.add(folder)
        for bundle in sorted(folder.glob("*.dSYM")):
            output = run_tool(["dwarfdump", "--uuid", str(bundle)])
            for uuid, arch, path in parse_dwarfdump_uuids(output or ""):
                self.by_uuid.setdefault(uuid, (arch, path))

    def find(self, uuid: str, build) -> tuple[str, Path] | None:
        uuid = uuid.upper()
        if uuid in self.by_uuid:
            return self.by_uuid[uuid]
        if isinstance(build, int) and not isinstance(build, bool):
            self._scan(self.root / str(build))
        if uuid not in self.by_uuid and self.root.is_dir():
            for folder in sorted(p for p in self.root.iterdir() if p.is_dir()):
                self._scan(folder)
                if uuid in self.by_uuid:
                    break
        return self.by_uuid.get(uuid)

    def text_vmaddr(self, arch: str, path: Path) -> int:
        if path not in self.vmaddr:
            output = run_tool(["otool", "-arch", arch, "-l", str(path)])
            self.vmaddr[path] = (parse_text_vmaddr(output or "") if output else None) or DEFAULT_TEXT_VMADDR
        return self.vmaddr[path]


def atos_one(arch: str, dwarf: Path, load: int, address: int) -> str | None:
    output = run_tool(["atos", "-o", str(dwarf), "-arch", arch, "-l", hex(load), hex(address)])
    if output is None:
        return None
    first = output.strip().splitlines()[0] if output.strip() else ""
    return first if atos_resolved(first) else None


def symbolicate(frame: dict, build, index: DsymIndex) -> tuple[str | None, str | None]:
    """(symbol, why not). One of the two is None."""
    uuid = frame.get("binaryUUID")
    if not isinstance(uuid, str):
        return None, "no binary UUID in the report"
    entry = index.find(uuid, build)
    if not entry:
        return None, f"no kept dSYM has UUID {clean(uuid, 60)}"
    arch, dwarf = entry
    where = load_and_address(frame, index.text_vmaddr(arch, dwarf))
    if not where:
        return None, "frame has no offset"
    symbol = atos_one(arch, dwarf, *where)
    return (symbol, None) if symbol else (None, "atos found no symbol")


# ---- the Worker side --------------------------------------------------------------------

def op(*args: str) -> bytes:
    return subprocess.check_output(["op", *args])


def field(item: str, name: str) -> str:
    return op("item", "get", item, "--vault", _op_id('VAULT'), "--fields", name, "--reveal").decode().strip()


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect would forward the secrets to somewhere else."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"refused redirect to {urllib.parse.urlsplit(newurl).netloc}",
                                     headers, fp)


_NO_REDIRECTS = urllib.request.build_opener(_RefuseRedirects)


def worker_origin() -> str:
    parts = urllib.parse.urlsplit(WORKER)
    if parts.scheme != "https" or not parts.netloc or parts.path or parts.query:
        sys.exit(f"MEETSPIKE_ORIGIN must be an https origin like https://your-worker.example.com, got {clean(WORKER, 100)!r}.")
    return WORKER


def transient(error: Exception) -> bool:
    if isinstance(error, urllib.error.HTTPError):
        return error.code == 429 or error.code >= 500
    return isinstance(error, (urllib.error.URLError, TimeoutError, ConnectionError))


def get_json(path: str):
    """GET the Worker path with the secrets read from 1Password right now. Exits with a plain
    message on any failure."""
    origin = worker_origin()
    try:
        headers = {"User-Agent": USER_AGENT, "Accept": "application/json",
                   "Authorization": f"Bearer {field(_op_id('INGEST_ITEM'), 'credential')}",
                   "CF-Access-Client-Id": field(_op_id('ACCESS_ITEM'), "client_id"),
                   "CF-Access-Client-Secret": field(_op_id('ACCESS_ITEM'), "client_secret")}
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Could not read the secrets from 1Password ({type(error).__name__}). Is `op` signed in?")
    for attempt in range(1, 4):
        request = urllib.request.Request(f"{origin}{path}", headers=headers)
        try:
            with _NO_REDIRECTS.open(request, timeout=30) as response:
                raw = response.read(MAX_REPLY_BYTES + 1)
            if len(raw) > MAX_REPLY_BYTES:
                sys.exit("The Worker's reply was too big to read.")
            return json.loads(raw)
        except json.JSONDecodeError:
            sys.exit("The Worker's reply was not JSON. Is Cloudflare Access in the way?")
        except urllib.error.HTTPError as error:
            if transient(error) and attempt < 3:
                time.sleep(3 * attempt)
                continue
            sys.exit(f"The Worker said {error.code} {clean(error.reason, 80)}.")
        except Exception as error:
            if transient(error) and attempt < 3:
                time.sleep(3 * attempt)
                continue
            sys.exit(f"Could not reach the Worker: {clean(error, 200)}")
    sys.exit("Could not reach the Worker.")


# ---- the two commands -------------------------------------------------------------------

def list_reports(limit: int) -> None:
    reply = get_json(f"{ENDPOINT}?limit={limit}")
    rows = reply.get("reports") if isinstance(reply, dict) and reply.get("ok") is True else None
    if not isinstance(rows, list):
        sys.exit("The Worker's list reply was not in the expected shape.")
    if not rows:
        print("No reports.")
        return
    for row in rows[:limit]:
        if not isinstance(row, dict):
            continue
        parts = [clean(row.get("at") or "?", 30), f"{clean(row.get('kind') or '?', 12):<6}",
                 f"build {clean(row.get('build') if row.get('build') is not None else '?', 8):<4}",
                 clean(row.get("device") or "?", 30), clean(row.get("id") or "?", 40)]
        signature = row.get("signature")
        print("  ".join(parts) + (f"\n    {clean(signature, 200)}" if signature else ""))
    print(f"\n{len(rows)} shown. Read one with: python3 ios/crash-reports.py --show <id>")


def show_report(report_id: str, dsym_root: Path) -> None:
    doc = get_json(f"{ENDPOINT}/{report_id}")
    if not isinstance(doc, dict):
        sys.exit("The Worker's report was not in the expected shape.")
    build = doc.get("build")
    print(f"id        {clean(doc.get('id'), 40)}")
    for key in ("kind", "at", "build", "version", "os", "device", "signature"):
        if doc.get(key) is not None:
            print(f"{key:<9} {clean(doc[key], 300)}")
    report = doc.get("report")
    meta = report.get("diagnosticMetaData") if isinstance(report, dict) else None
    if isinstance(meta, dict):
        for key in sorted(meta):
            if isinstance(meta[key], (str, int, float, bool)):
                print(f"{clean(key, 40):<24} {clean(meta[key], 200)}")

    index = DsymIndex(dsym_root)
    reasons: dict[str, int] = {}
    for number, (attributed, frames) in enumerate(walk_frames(report), start=1):
        print(f"\nCall stack {number}{' (the thread that hit it)' if attributed else ''}")
        for depth, frame in frames:
            name = clean(frame.get("binaryName") or "?", 60)
            offset = as_int(frame.get("offsetIntoBinaryTextSegment"))
            where = f"{name}+{offset}" if offset is not None else name
            samples = as_int(frame.get("sampleCount"))
            count = f"  x{samples}" if samples and samples > 1 else ""
            line = f"{depth:>4}  {where}{count}"
            if frame.get("binaryName") == APP_BINARY:
                symbol, why = symbolicate(frame, build, index)
                if symbol:
                    line += f"  {clean(symbol, 300)}"
                else:
                    line += f"  (not symbolicated: {why})"
                    reasons[why] = reasons.get(why, 0) + 1
            print(line)
    if reasons:
        print(f"\nSome {APP_BINARY} frames were not symbolicated. dSYMs are read from {dsym_root}.")
        if any(why.startswith("no kept dSYM") for why in reasons):
            print("No kept dSYM matches this report's binary UUID. It is only kept for builds released with "
                  "ios/release-testflight.py (build 8 and later). If you still have the .xcarchive, copy its "
                  f"dSYMs folder contents into {dsym_root}/<build>/.")
    crumbs = doc.get("crumbs")
    if isinstance(crumbs, list) and crumbs:
        print(f"\nBreadcrumbs ({len(crumbs)}, oldest first)")
        print("From the session before the report arrived. Compare the times with the crash time.")
        for crumb in crumbs:
            print(f"  {clean(crumb, 200)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="List and read Meetspike iPhone crash reports.")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help=f"how many to list (1 to {MAX_LIMIT})")
    parser.add_argument("--show", metavar="ID", help="print one report, symbolicated")
    parser.add_argument("--dsyms", type=Path, default=DSYM_HOME, help="folder of kept dSYMs, one folder per build")
    args = parser.parse_args()
    if args.show is not None:
        report_id = valid_id(args.show)
        if not report_id:
            sys.exit("--show needs a report id (a UUID, as listed without --show).")
        show_report(report_id, args.dsyms)
    else:
        if not 1 <= args.limit <= MAX_LIMIT:
            sys.exit(f"--limit must be 1 to {MAX_LIMIT}.")
        list_reports(args.limit)


if __name__ == "__main__":
    main()
