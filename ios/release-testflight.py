#!/usr/bin/env python3
"""Archive Meetspike, upload it to TestFlight, wait for App Store Connect to
process it, then tell the Worker so the app shows "Update available".

    python3 ios/release-testflight.py              # archive, upload, wait, announce
    python3 ios/release-testflight.py --announce   # build already uploaded: wait, announce

Bump CURRENT_PROJECT_VERSION in ios/MeetspikeHR/project.yml first (one
project-level value shared by the app and its widget extension). Secrets come
from 1Password (Shared vault) at run time and never touch the repo or the logs. The App Store Connect key stays in memory, and is written to a 0600
file only while each xcodebuild call runs. Runs on the Mac (Xcode), with the
system PATH because Homebrew rsync breaks -exportArchive ("Copy failed").

Two extras, both warn-only (a failure here never fails the release):
  - the archive's dSYMs are kept under ~/Library/Application Support/Meetspike/dSYMs/<build>/
    so ios/crash-reports.py can symbolicate crash reports later;
  - once the build is valid, TestFlight's "What to Test" (en-US) is set from that build's
    items in ReleaseNotes.swift, the single source for the notes.
"""
import base64, json, os, re, shutil, signal, subprocess, sys, tempfile, time
import urllib.error, urllib.parse, urllib.request
from contextlib import contextmanager
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "MeetspikeHR"
RELEASE_NOTES = ROOT.parent / "shared/MeetspikeHRCore/Sources/MeetspikeHRCore/Mobile/Diagnostics/ReleaseNotes.swift"
# Kept dSYMs, one folder per build. ios/crash-reports.py reads the same place.
DSYM_HOME = Path(os.environ.get("MEETSPIKE_DSYM_DIR")
                 or Path.home() / "Library/Application Support/Meetspike/dSYMs")
ASC_API = "https://api.appstoreconnect.apple.com"
WHATS_NEW_MAX = 4000  # App Store Connect's limit for whatsNew
APP_ID = "6838520447"
TEAM = "3L9KVW55SQ"
KEY_ID = "PC24DQR58N"
ISSUER = "94be2d6d-f611-4c9b-a8ad-d490f7bd93ed"
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
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
# Cloudflare blocks urllib's default "Python-urllib/3.x" agent (error 1010).
USER_AGENT = "meetspike-release/1"
POLL_SECONDS = 60
POLL_LIMIT = 45 * 60
POST_ATTEMPTS = 4

# Key files written for xcodebuild; removed after each call and on SIGTERM.
_key_files: set[Path] = set()


def _remove_key_files() -> None:
    for path in list(_key_files):
        path.unlink(missing_ok=True)
        _key_files.discard(path)


def _on_sigterm(signum, frame) -> None:
    _remove_key_files()
    sys.exit(128 + signum)


def op(*args: str) -> bytes:
    return subprocess.check_output(["op", *args])


def field(item: str, name: str) -> str:
    return op("item", "get", item, "--vault", _op_id('VAULT'), "--fields", name, "--reveal").decode().strip()


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def asc_token(key_pem: bytes) -> str:
    header = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    now = int(time.time())
    claims = b64(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    key = serialization.load_pem_private_key(key_pem, password=None)
    r, s = decode_dss_signature(key.sign(f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256())))
    return f"{header}.{claims}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect would turn the POST into a GET and forward the secrets."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"refused redirect to {urllib.parse.urlsplit(newurl).netloc}",
                                     headers, fp)


_NO_REDIRECTS = urllib.request.build_opener(_RefuseRedirects)


def transient(error: Exception) -> bool:
    """Worth retrying: network trouble, rate limits and server errors."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code == 429 or error.code >= 500
    return isinstance(error, (urllib.error.URLError, TimeoutError, ConnectionError))


def build_state(key_pem: bytes, build: int) -> str | None:
    url = (f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={APP_ID}"
           f"&filter[version]={build}&fields[builds]=processingState&limit=1")
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {asc_token(key_pem)}",
                                                   "User-Agent": USER_AGENT})
    with _NO_REDIRECTS.open(request, timeout=30) as response:
        data = json.load(response).get("data", [])
    return data[0]["attributes"]["processingState"] if data else None


def wait_until_valid(key_pem: bytes, build: int) -> None:
    print("Waiting for App Store Connect to process it...")
    deadline = time.time() + POLL_LIMIT
    while True:
        try:
            state = build_state(key_pem, build)
        except Exception as error:
            if not transient(error):
                raise
            print(f"App Store Connect check failed ({error}). Trying again.")
            state = "unknown"
        if state == "VALID":
            return
        if state in ("FAILED", "INVALID"):
            sys.exit(f"Build {build} processing {state}.")
        if time.time() > deadline:
            sys.exit(f"Build {build} still {state or 'not listed'} after 45 minutes. "
                     f"Rerun later with: python3 ios/release-testflight.py --announce")
        time.sleep(POLL_SECONDS)


def keep_dsyms(archive: Path, build: int) -> None:
    """Copy the archive's dSYMs to DSYM_HOME/<build>/. Warns on trouble, never raises.

    Existing files are overwritten and nothing is deleted, so a rerun is safe."""
    try:
        source = archive / "dSYMs"
        bundles = sorted(source.glob("*.dSYM")) if source.is_dir() else []
        if not bundles:
            print(f"Warning: no dSYMs in the archive, so crash reports for build {build} will not symbolicate.")
            return
        target = DSYM_HOME / str(build)
        target.mkdir(parents=True, exist_ok=True)
        for bundle in bundles:
            shutil.copytree(bundle, target / bundle.name, symlinks=True, dirs_exist_ok=True)
        print(f"Kept {len(bundles)} dSYM(s) in {target}")
    except Exception as error:
        print(f"Warning: could not keep the dSYMs for build {build}: {error}")


_SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def _swift_string(body: str) -> str:
    out, i = [], 0
    while i < len(body):
        char = body[i]
        if char != "\\":
            out.append(char)
            i += 1
            continue
        nxt = body[i + 1:i + 2]
        if nxt == "u":
            end = body.find("}", i)
            if body[i + 2:i + 3] != "{" or end < 0:
                raise ValueError(f"bad unicode escape in {body!r}")
            out.append(chr(int(body[i + 3:end], 16)))
            i = end + 1
        elif nxt in _SWIFT_ESCAPES:
            out.append(_SWIFT_ESCAPES[nxt])
            i += 2
        else:
            raise ValueError(f"unsupported escape \\{nxt} in {body!r}")
    return "".join(out)


def _swift_string_list(body: str) -> list[str]:
    """The string literals of a Swift array body. Comments are skipped; anything else is an error."""
    items, i = [], 0
    while i < len(body):
        char = body[i]
        if char.isspace() or char == ",":
            i += 1
        elif body.startswith("//", i):
            end = body.find("\n", i)
            i = len(body) if end < 0 else end
        elif char == '"':
            j = i + 1
            while j < len(body) and body[j] != '"':
                j += 2 if body[j] == "\\" else 1
            if j >= len(body):
                raise ValueError("unterminated string")
            items.append(_swift_string(body[i + 1:j]))
            i = j + 1
        else:
            raise ValueError(f"unexpected text in items: {body[i:i + 30]!r}")
    return items


_RELEASE_BLOCK = re.compile(r'Release\(\s*build:\s*(\d+)\s*,\s*version:\s*"[^"]*"\s*,\s*date:\s*"[^"]*"\s*,'
                            r'\s*items:\s*\[(.*?)\n\s*\]\s*,?\s*\)', re.S)


def parse_release_notes(text: str) -> dict[int, list[str]]:
    """Build number to its items, from the `Release(build:..., items: [...])` blocks of ReleaseNotes.swift.
    The first block for a build wins. Raises ValueError on a block it cannot read."""
    notes: dict[int, list[str]] = {}
    for match in _RELEASE_BLOCK.finditer(text):
        notes.setdefault(int(match.group(1)), _swift_string_list(match.group(2)))
    return notes


def notes_text(items: list[str]) -> str:
    """"- item" lines, the same shape as ReleaseNotes.notesText(build:), kept under App Store Connect's limit."""
    lines = [f"- {item}" for item in items if item.strip()]
    while lines and len("\n".join(lines)) > WHATS_NEW_MAX:
        lines.pop()
    return "\n".join(lines)


def asc_call(key_pem: bytes, method: str, path: str, body: dict | None = None) -> dict:
    """One App Store Connect call, retried on network trouble, rate limits and server errors."""
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(1, 4):
        headers = {"Authorization": f"Bearer {asc_token(key_pem)}", "User-Agent": USER_AGENT}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"{ASC_API}{path}", method=method, data=data, headers=headers)
        try:
            with _NO_REDIRECTS.open(request, timeout=30) as response:
                raw = response.read()
            return json.loads(raw) if raw else {}
        except Exception as error:
            if not transient(error) or attempt == 3:
                raise
            time.sleep(3 * attempt)
    raise RuntimeError("unreachable")


def set_whats_new(key_pem: bytes, build: int) -> None:
    """Set TestFlight's en-US "What to Test" for this build. Warns on any trouble, never raises."""
    try:
        notes = parse_release_notes(RELEASE_NOTES.read_text(encoding="utf-8"))
        items = notes.get(build)
        text = notes_text(items) if items else ""
        if not text:
            print(f"Warning: no release notes for build {build} in ReleaseNotes.swift, so What to Test is unchanged.")
            return
        found = asc_call(key_pem, "GET", f"/v1/builds?filter[app]={APP_ID}&filter[version]={build}&fields[builds]=version&limit=1")
        if not found.get("data"):
            print(f"Warning: build {build} is not listed on App Store Connect, so What to Test is unchanged.")
            return
        build_id = found["data"][0]["id"]
        existing = asc_call(key_pem, "GET", f"/v1/builds/{build_id}/betaBuildLocalizations?limit=50")
        current = next((row for row in existing.get("data", [])
                        if row.get("attributes", {}).get("locale") == "en-US"), None)
        if current:
            asc_call(key_pem, "PATCH", f"/v1/betaBuildLocalizations/{current['id']}",
                     {"data": {"type": "betaBuildLocalizations", "id": current["id"],
                               "attributes": {"whatsNew": text}}})
        else:
            asc_call(key_pem, "POST", "/v1/betaBuildLocalizations",
                     {"data": {"type": "betaBuildLocalizations",
                               "attributes": {"locale": "en-US", "whatsNew": text},
                               "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        print(f"What to Test set for build {build} ({len(items)} items).")
    except Exception as error:
        print(f"Warning: could not set What to Test for build {build}: {_clean(str(error))}")


def _clean(text: str) -> str:
    return "".join(ch if ch.isprintable() else " " for ch in text)[:300]


def worker_origin() -> str:
    parts = urllib.parse.urlsplit(WORKER)
    if parts.scheme != "https" or not parts.netloc or parts.path or parts.query:
        sys.exit(f"MEETSPIKE_ORIGIN must be an https origin like https://your-worker.example.com, got {WORKER!r}.")
    return WORKER


def announce(build: int) -> None:
    origin = worker_origin()
    headers = {"Content-Type": "application/json",
               "User-Agent": USER_AGENT,
               "Authorization": f"Bearer {field(_op_id('INGEST_ITEM'), 'credential')}",
               "CF-Access-Client-Id": field(_op_id('ACCESS_ITEM'), "client_id"),
               "CF-Access-Client-Secret": field(_op_id('ACCESS_ITEM'), "client_secret")}
    body = json.dumps({"build": build}).encode()
    for attempt in range(1, POST_ATTEMPTS + 1):
        request = urllib.request.Request(f"{origin}/api/whoop-web/app/ios", method="POST", data=body, headers=headers)
        try:
            with _NO_REDIRECTS.open(request, timeout=30) as response:
                reply = json.load(response)
            break
        except Exception as error:
            if not transient(error) or attempt == POST_ATTEMPTS:
                sys.exit(f"Could not tell the Worker about build {build}: {error}. "
                         f"Rerun with: python3 ios/release-testflight.py --announce")
            print(f"Worker POST failed ({error}). Trying again.")
            time.sleep(5 * attempt)
    stored = reply.get("build") if isinstance(reply, dict) else None
    if stored != build:
        sys.exit(f"Worker kept build {stored}, not {build} (it only moves forward). Reply: {reply}")
    print(f"Build {build} is live in TestFlight. Worker says: {reply}")


@contextmanager
def key_file(key_pem: bytes, directory: Path):
    """The .p8 exists only while the xcodebuild call that needs it runs."""
    path = directory / f"AuthKey_{KEY_ID}.p8"
    _key_files.add(path)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(key_pem)
        yield path
    finally:
        path.unlink(missing_ok=True)
        _key_files.discard(path)


def xcodebuild(key_pem: bytes, keys: Path, args: list[str], env: dict) -> None:
    with key_file(key_pem, keys) as key_path:
        auth = ["-allowProvisioningUpdates", "-authenticationKeyPath", str(key_path),
                "-authenticationKeyID", KEY_ID, "-authenticationKeyIssuerID", ISSUER]
        subprocess.run(["xcodebuild", "-quiet", *args, *auth], cwd=PROJECT, env=env, check=True)


def main() -> None:
    signal.signal(signal.SIGTERM, _on_sigterm)
    announce_only = "--announce" in sys.argv[1:]
    builds = set(re.findall(r'CURRENT_PROJECT_VERSION:\s*"?(\d+)"?', (PROJECT / "project.yml").read_text()))
    if not builds:
        sys.exit("CURRENT_PROJECT_VERSION not found in project.yml")
    if len(builds) > 1:
        # The widget extension must ship the app's build number.
        sys.exit(f"project.yml sets CURRENT_PROJECT_VERSION more than once ({sorted(builds)}). "
                 f"Keep the single project-level value.")
    build = int(builds.pop())
    worker_origin()
    key_pem = op("document", "get", _op_id('ASC_KEY_DOC'), "--vault", _op_id('VAULT'))

    if announce_only:
        if not build_state(key_pem, build):
            sys.exit(f"Build {build} is not on App Store Connect yet. Run without --announce to upload it.")
        wait_until_valid(key_pem, build)
        set_whats_new(key_pem, build)
        announce(build)
        return

    if build_state(key_pem, build):
        sys.exit(f"Build {build} is already on App Store Connect. To finish announcing it, run: "
                 f"python3 ios/release-testflight.py --announce. For a new release, bump CURRENT_PROJECT_VERSION.")

    env = dict(os.environ, PATH=SYSTEM_PATH)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            keys = Path(tmp) / "keys"
            keys.mkdir(mode=0o700)
            subprocess.run(["xcodegen", "generate"], cwd=PROJECT, check=True, capture_output=True)
            archive = Path(tmp) / "MeetspikeHR.xcarchive"
            print(f"Archiving build {build}...")
            xcodebuild(key_pem, keys, ["-project", "MeetspikeHR.xcodeproj", "-scheme", "MeetspikeHR",
                                       "-destination", "generic/platform=iOS", "-archivePath", str(archive),
                                       "archive"], env)
            keep_dsyms(archive, build)
            options = Path(tmp) / "ExportOptions.plist"
            options.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>{TEAM}</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
""")
            print("Uploading to TestFlight...")
            xcodebuild(key_pem, keys, ["-exportArchive", "-archivePath", str(archive),
                                       "-exportOptionsPlist", str(options), "-exportPath", str(Path(tmp) / "export")],
                       env)
    finally:
        _remove_key_files()

    wait_until_valid(key_pem, build)
    set_whats_new(key_pem, build)
    announce(build)


if __name__ == "__main__":
    main()
