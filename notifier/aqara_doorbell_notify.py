#!/usr/bin/env python3
"""Aqara G410 -> Matrix motion notifier.

Polls the Aqara "intelligent/query" event-history endpoint, and for every new
event posts its snapshot thumbnail to a Matrix room. All Aqara crypto is the
reverse-engineered scheme from this repo:

  - login:   RSA/ECB/PKCS1( md5hex(password) ), base64  (AqaraCloud.swift)
  - signing: md5( "k=v&..." sorted + "&" + appKey )     (re/poc.py)
  - media:   AES-128-CBC, key = bytes.fromhex(event.key), fixed IV, PKCS#7
             (re/cos_decrypt.py); object fetched from Tencent COS with the
             per-response STS creds via AWS SigV4 (re/s3get.py)

Runs as a long-lived loop; state (last seen triggerTime) persists to STATE_DIR
so a restart does not re-announce old events. Re-logs in automatically when the
session token is rejected. Stdlib only, except `cryptography` for AES/RSA.
"""
from __future__ import annotations

import base64
import datetime
import hashlib
import hmac
import json
import logging
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.serialization import load_pem_public_key

log = logging.getLogger("aqara-doorbell")

# RSA-1024 public key baked into the Aqara app; encrypts the login password.
LOGIN_PUBKEY_PEM = b"""-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCG46slB57013JJs4Vvj5cVyMpR
9b+B2F+YJU6qhBEYbiEmIdWpFPpOuBikDs2FcPS19MiWq1IrmxJtkICGurqImRUt
4lP688IWlEmqHfSxSRf2+aH0cH8VWZ2OaZn5DWSIHIPBF2kxM71q8stmoYiV0oZs
rZzBHsMuBwA4LQdxBwIDAQAB
-----END PUBLIC KEY-----"""

# Fixed IV for event-media AES-128-CBC (re/cos_decrypt.py).
MEDIA_IV = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")

EVENT_QUERY = "/app/v1.0/lumi/devex/camera/video/intelligent/query"
LOGIN_PATH = "/app/v1.0/lumi/user/login"


def env(name: str, default: str | None = None, required: bool = False) -> str:
    """Read config from an env var, or from a systemd LoadCredential file
    ``<CREDENTIALS_DIRECTORY>/<name>`` when the env var is unset."""
    val = os.environ.get(name)
    if val is None:
        cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
        if cred_dir:
            path = os.path.join(cred_dir, name)
            if os.path.exists(path):
                val = open(path, encoding="utf-8").read().strip()
    if val is None:
        val = default
    if required and not val:
        log.error("missing required config: %s", name)
        sys.exit(2)
    return val or ""


class Aqara:
    def __init__(self) -> None:
        self.host = env("AQARA_HOST", "https://rpc-ger.aqara.com").rstrip("/")
        self.app_id = env("AQARA_APPID", "444c476ef7135e53330f46e7")
        self.app_key = env("AQARA_APPKEY", "uOJy0qmKwXj6aHUB2KQEIJuXHMDVTAJi")
        self.area = env("AQARA_AREA", "NG")
        self.email = env("AQARA_EMAIL", required=True)
        self.password = env("AQARA_PASSWORD", required=True)
        self.position_id = env("AQARA_POSITION_ID", "")  # discovered if unset/not owned
        self.did = env("AQARA_DID", "")
        self.token: str | None = None
        self.user_id: str | None = None

    # -- crypto ---------------------------------------------------------------
    @staticmethod
    def _md5_hex(s: str) -> str:
        return hashlib.md5(s.encode()).hexdigest()

    def _encrypt_password(self) -> str:
        pub = load_pem_public_key(LOGIN_PUBKEY_PEM)
        md5pw = self._md5_hex(self.password).encode()  # 32 ascii hex chars
        return base64.b64encode(pub.encrypt(md5pw, padding.PKCS1v15())).decode()

    @staticmethod
    def _jwt_sub(tok: str) -> str:
        payload = tok.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("sub", "")

    def _headers(self, sign_body: str) -> dict:
        """Sign = MD5("Appid=..&Nonce=..&Time=..[&Token=..][&<sign_body>]&appKey")
        with the auth fields in that fixed order (AqaraCloud.swift). For a GET,
        ``sign_body`` is the request params as sorted "k=v&..." with raw values;
        for a POST it is the exact JSON body string that is sent."""
        nonce = uuid.uuid4().hex
        t = str(int(time.time() * 1000))
        pre = f"Appid={self.app_id}&Nonce={nonce}&Time={t}"
        if self.token:
            pre += f"&Token={self.token}"
        if sign_body:
            pre += f"&{sign_body}"
        pre += f"&{self.app_key}"
        headers = {
            "Appid": self.app_id, "Nonce": nonce, "Time": t, "Sign": self._md5_hex(pre),
            "Area": self.area, "Lang": "en", "App-Version": "4.3.8",
            "Sys-Type": "1", "Sys-Version": "18.0",
            "Content-Type": "application/json",
        }
        if self.token:
            headers["Token"] = self.token
        if self.user_id:
            headers["Userid"] = self.user_id
        return headers

    # -- transport ------------------------------------------------------------
    def _req(self, method: str, path: str, params: dict | None = None,
             body: dict | None = None) -> dict:
        url = self.host + path
        sign_body = ""
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode()
            sign_body = data.decode()  # POST: sign the exact body string
        if params:
            items = sorted((k, v) for k, v in params.items() if v != "" and v is not None)
            sign_body = "&".join(f"{k}={v}" for k, v in items)  # GET: sorted raw params
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, data=data, method=method,
                                     headers=self._headers(sign_body))
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())

    def login(self) -> None:
        self.token = None
        self.user_id = None
        body = {"account": self.email, "encryptType": 2, "password": self._encrypt_password()}
        res = self._req("POST", LOGIN_PATH, body=body)
        if res.get("code") != 0:
            raise RuntimeError(f"login failed: code={res.get('code')} {res.get('msgDetails')}")
        tok = (res.get("result") or {}).get("token")
        if not tok:
            raise RuntimeError("login response had no token")
        self.token = tok
        self.user_id = self._jwt_sub(tok)
        log.info("logged in as %s", self.user_id)

    def resolve_targets(self) -> None:
        """Discover this account's camera and home. intelligent/query wants the
        home-level positionId (real1.*, from the home list), not the device's
        room positionId. A configured positionId that the account does not own
        returns code 710, so prefer a discovered home and only keep the
        configured one when it is actually ours."""
        dres = self._req("GET", "/app/v1.0/lumi/app/position/device/query")
        dresult = dres.get("result") or {}
        devices = (dresult.get("devices") if isinstance(dresult, dict) else dresult) or []
        if not devices:
            log.warning("device query returned none (result shape: %s)",
                        list(dresult) if isinstance(dresult, dict) else type(dresult).__name__)
        for d in devices:
            log.info("device: did=%s model=%s name=%s pos=%s",
                     d.get("did"), d.get("model"), d.get("deviceName"), d.get("positionId"))
        hres = self._req("GET", "/app/v1.0/lumi/app/position/query/home/list")
        homes = ((hres.get("result") or {}).get("homes")) or []
        home_ids = [h.get("homeId") for h in homes if h.get("homeId")]
        log.info("homes: %s", home_ids)

        # Prefer a camera's did from discovery (overriding a stale configured
        # one); with no devices found, clear it so the query scans the whole
        # home (deviceIds=[]).
        cam = next((d for d in devices if "camera" in (d.get("model") or "").lower()),
                   devices[0] if devices else None)
        if cam:
            self.did = cam.get("did", "")
            log.info("using camera did %s (%s)", self.did, cam.get("model"))
        else:
            self.did = ""
        if self.position_id not in home_ids:
            if home_ids:
                log.warning("configured positionId %s not owned; using home %s",
                            self.position_id or "(none)", home_ids[0])
                self.position_id = home_ids[0]
            else:
                log.error("account %s owns no homes; cannot query events", self.user_id)

    def _query_once(self, since_ms: int, size: int = 20) -> dict:
        now = int(time.time() * 1000)
        device_ids = f'["{self.did}"]' if self.did else "[]"
        params = {
            "aiDataType": 0, "aiSortType": 0, "aiTagList": "[]",
            "deviceIds": device_ids, "endTime": now, "positionId": self.position_id,
            "reversed": 1, "size": size, "startIndex": 0,
            "startTime": since_ms, "videoTypeList": "[]",
        }
        return self._req("GET", EVENT_QUERY, params=params)

    def query_events(self, since_ms: int) -> list[dict]:
        """Return event dicts since ``since_ms``. Any non-zero return code
        (the exact token-expiry codes are not pinned down) triggers one
        re-login and retry before giving up."""
        res = self._query_once(since_ms)
        if res.get("code") != 0:
            log.info("query code=%s (%s); re-logging in and retrying",
                     res.get("code"), res.get("msgDetails"))
            self.login()
            res = self._query_once(since_ms)
        if res.get("code") != 0:
            raise RuntimeError(f"query failed: code={res.get('code')} {res.get('msgDetails')}")
        result = res.get("result") or {}
        files = result.get("cameraFileList") or []
        default_sts = result.get("defaultAwsStsFile") or result
        for item in files:
            item.setdefault("_sts", item.get("awsStsFile") or default_sts)
        return files


# -- Tencent COS (S3-compatible) GET with STS temp creds + AES decrypt --------
def _sigv4_get(sts: dict, bucket: str, endpoint: str, region: str, key_path: str) -> bytes:
    ak, sk, tok = sts["awsAccessKey"], sts["awsSecretKey"], sts["sessionToken"]
    host = f"{bucket}.{endpoint}"
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    canonical_uri = "/" + urllib.parse.quote(key_path)
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_headers = (f"host:{host}\nx-amz-content-sha256:{payload_hash}\n"
                         f"x-amz-date:{amzdate}\nx-amz-security-token:{tok}\n")
    signed_headers = "host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
    canonical_request = f"GET\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    scope = f"{datestamp}/{region}/s3/aws4_request"
    string_to_sign = (f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n"
                      f"{hashlib.sha256(canonical_request.encode()).hexdigest()}")

    def _sign(k: bytes, msg: str) -> bytes:
        return hmac.new(k, msg.encode(), hashlib.sha256).digest()

    k = _sign(("AWS4" + sk).encode(), datestamp)
    k = _sign(k, region)
    k = _sign(k, "s3")
    k = _sign(k, "aws4_request")
    sig = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
            f"SignedHeaders={signed_headers}, Signature={sig}")
    req = urllib.request.Request(f"https://{host}{canonical_uri}", headers={
        "Host": host, "x-amz-date": amzdate, "x-amz-content-sha256": payload_hash,
        "x-amz-security-token": tok, "Authorization": auth})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def _decrypt_media(ciphertext: bytes, event_key: str) -> bytes:
    key = bytes.fromhex(event_key)
    if not ciphertext or len(ciphertext) % 16:
        raise ValueError("ciphertext not a multiple of the AES block size")
    padded = Cipher(algorithms.AES(key), modes.CBC(MEDIA_IV)).decryptor()
    plain = padded.update(ciphertext) + padded.finalize()
    pad = plain[-1]
    if pad < 1 or pad > 16 or plain[-pad:] != bytes([pad]) * pad:
        raise ValueError("invalid PKCS#7 padding: wrong key or damaged ciphertext")
    return plain[:-pad]


def _fetch_media(item: dict, name: str) -> bytes | None:
    """Download and decrypt one COS object (snapshot or clip) for an event.
    None if the object is unavailable (e.g. the clip is not uploaded yet)."""
    sts = item.get("_sts") or {}
    key = item.get("key") or ""
    if not name or not key or not sts.get("awsAccessKey"):
        return None
    bucket = item.get("bucket") or sts.get("bucketName") or ""
    endpoint = (item.get("endpoint") or sts.get("endpoint") or "").replace("https://", "").strip("/")
    region = sts.get("region", "eu-frankfurt")
    object_key = (item.get("path") or "") + name
    try:
        raw = _sigv4_get(sts, bucket, endpoint, region, object_key)
    except urllib.error.HTTPError as e:
        if e.code in (403, 404):  # not uploaded / expired yet
            return None
        raise
    if raw[:3] == b"\xff\xd8\xff":  # already plaintext JPEG
        return raw
    return _decrypt_media(raw, key)


def fetch_snapshot(item: dict) -> bytes | None:
    """The event's snapshot JPEG, or None."""
    return _fetch_media(item, item.get("snapshotName") or "")


def fetch_video(item: dict) -> bytes | None:
    """The event's clip as MP4, or None when it is sliced (live-style, not a
    single container) or not uploaded yet / not a valid MP4."""
    if item.get("isSliced"):
        return None
    mp4 = _fetch_media(item, item.get("videoName") or "")
    if not mp4 or mp4[4:8] != b"ftyp":  # standard MP4 'ftyp' box
        return None
    return mp4


class Matrix:
    def __init__(self) -> None:
        self.hs = env("MATRIX_HOMESERVER", "https://matrix.example.org").rstrip("/")
        self.room = env("MATRIX_ROOM", required=True)
        # Either a ready access token, or user+password to obtain one.
        self.token = env("MATRIX_TOKEN", "")
        self.user = env("MATRIX_USER", "")
        self.password = env("MATRIX_PASSWORD", "")
        if not self.token and not (self.user and self.password):
            log.error("Matrix needs MATRIX_TOKEN, or MATRIX_USER + MATRIX_PASSWORD")
            sys.exit(2)

    def _req(self, method: str, path: str, body: bytes | None, content_type: str,
             auth: bool = True) -> dict:
        headers = {"Content-Type": content_type}
        if auth:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.hs + path, data=body, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())

    @staticmethod
    def _token_cache() -> str:
        sdir = os.environ.get("STATE_DIR") or os.environ.get("STATE_DIRECTORY")
        return os.path.join(sdir, "matrix_token.txt") if sdir else ""

    def login(self) -> None:
        if self.token:
            return
        # Reuse a cached access token so a restart does not hit Synapse's
        # rc_login rate limit; fall back to password login if it is stale.
        cache = self._token_cache()
        if cache and os.path.exists(cache):
            try:
                self.token = open(cache).read().strip()
                who = self._req("GET", "/_matrix/client/v3/account/whoami", None, "application/json")
                log.info("matrix token reused for %s", who.get("user_id"))
                return
            except Exception:
                self.token = ""  # stale/invalid; re-login below
        body = json.dumps({
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": self.user},
            "password": self.password,
        }).encode()
        res = self._req("POST", "/_matrix/client/v3/login", body, "application/json", auth=False)
        self.token = res["access_token"]
        log.info("matrix logged in as %s", res.get("user_id"))
        if cache:
            try:
                tmp = cache + ".tmp"
                with open(tmp, "w") as f:
                    f.write(self.token)
                os.replace(tmp, cache)
                os.chmod(cache, 0o600)
            except OSError:
                pass

    def _join(self, room: str) -> dict:
        path = f"/_matrix/client/v3/join/{urllib.parse.quote(room)}"
        return self._req("POST", path, b"{}", "application/json")

    def join(self) -> None:
        # No-op if already joined. A v12 room id is just !<hash> with no
        # :server part; a configured value with a stray :server suffix 404s, so
        # on 404 retry without it. A normal !local:server room joins first try,
        # so the fallback never fires for it.
        try:
            res = self._join(self.room)
        except urllib.error.HTTPError as e:
            if e.code == 404 and ":" in self.room:
                alt = self.room.rsplit(":", 1)[0]
                log.warning("join %s 404; retrying as %s", self.room, alt)
                res = self._join(alt)
            else:
                raise
        self.room = res.get("room_id", self.room)

    def upload(self, data: bytes, filename: str, content_type: str) -> str:
        path = "/_matrix/media/v3/upload?" + urllib.parse.urlencode({"filename": filename})
        return self._req("POST", path, data, content_type)["content_uri"]

    def _send(self, msgtype: str, caption: str, mxc: str, info: dict,
              thread_root: str | None = None) -> str:
        content: dict = {"msgtype": msgtype, "body": caption, "url": mxc, "info": info}
        if thread_root:
            content["m.relates_to"] = {
                "rel_type": "m.thread", "event_id": thread_root,
                "is_falling_back": True, "m.in_reply_to": {"event_id": thread_root},
            }
        txn = uuid.uuid4().hex
        path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(self.room)}/send/m.room.message/{txn}"
        res = self._req("PUT", path, json.dumps(content).encode(), "application/json")
        return res.get("event_id", "")

    def post_image(self, jpeg: bytes, caption: str) -> str:
        """Post the snapshot; returns its event id to use as a thread root."""
        mxc = self.upload(jpeg, "snapshot.jpg", "image/jpeg")
        return self._send("m.image", caption, mxc, {"mimetype": "image/jpeg", "size": len(jpeg)})

    def post_video(self, mp4: bytes, caption: str, thread_root: str | None = None) -> None:
        mxc = self.upload(mp4, "clip.mp4", "video/mp4")
        self._send("m.video", caption, mxc, {"mimetype": "video/mp4", "size": len(mp4)}, thread_root)


def _sleep_unless(stop: dict, seconds: int) -> None:
    """Sleep up to ``seconds``, waking early if the stop flag is set."""
    for _ in range(max(0, int(seconds))):
        if stop["flag"]:
            return
        time.sleep(1)


def main() -> None:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    poll = int(env("POLL_INTERVAL", "15"))
    state_dir = env("STATE_DIR", os.environ.get("STATE_DIRECTORY", "."))
    state_path = os.path.join(state_dir, "last_trigger.txt")

    stop = {"flag": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__("flag", True))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__("flag", True))

    aqara = Aqara()
    matrix = Matrix()

    # Connect with in-process backoff instead of exiting: a crash-exit would let
    # systemd restart us in a tight loop and keep tripping Synapse's rc_login /
    # rc_joins rate limits (HTTP 429), so the service could never settle.
    def connect() -> None:
        aqara.login()
        aqara.resolve_targets()
        matrix.login()
        matrix.join()

    delay = 5
    while not stop["flag"]:
        try:
            connect()
            break
        except urllib.error.HTTPError as e:
            wait = delay
            if e.code == 429:  # honor Synapse's retry hint
                try:
                    body = json.loads(e.read() or b"{}")
                    wait = max(wait, int(body.get("retry_after_ms", 0)) / 1000 + 1)
                except (ValueError, TypeError):
                    pass
            log.warning("connect failed (HTTP %s); retrying in %ds", e.code, int(wait))
            _sleep_unless(stop, int(wait))
            delay = min(delay * 2, 300)
        except Exception as e:
            log.warning("connect failed (%s); retrying in %ds", e, delay)
            _sleep_unless(stop, delay)
            delay = min(delay * 2, 300)
    if stop["flag"]:
        log.info("stopped before connect")
        return

    # Start from "now" on first run so we don't replay history; otherwise resume.
    try:
        last_seen = int(open(state_path).read().strip())
    except (OSError, ValueError):
        last_seen = int(time.time() * 1000)
        log.info("no state; starting from now (%d)", last_seen)

    while not stop["flag"]:
        try:
            events = aqara.query_events(since_ms=last_seen + 1)
            for item in sorted(events, key=lambda e: e.get("triggerTime", 0)):
                trigger = int(item.get("triggerTime", 0))
                if trigger <= last_seen:
                    continue
                name = item.get("videoEventName") or "Motion"
                when = datetime.datetime.fromtimestamp(trigger / 1000).strftime("%H:%M:%S")
                log.info("new event: %s @ %s (trigger=%d)", name, when, trigger)
                caption = f"🔔 {name} @ {when}"
                try:
                    root = None
                    jpeg = fetch_snapshot(item)
                    if jpeg:
                        root = matrix.post_image(jpeg, caption)  # instant thumbnail
                    else:
                        log.warning("event %d had no snapshot media yet", trigger)
                    # The clip uploads a few seconds after the snapshot; post it
                    # as a thread reply under the thumbnail when it is ready.
                    mp4 = fetch_video(item)
                    if mp4:
                        matrix.post_video(mp4, caption, thread_root=root)
                    else:
                        log.info("event %d clip not ready/sliced; snapshot only", trigger)
                except Exception:
                    log.exception("failed to deliver event %d", trigger)
                    continue  # don't advance last_seen past an undelivered event
                last_seen = trigger
                tmp = state_path + ".tmp"
                with open(tmp, "w") as f:
                    f.write(str(last_seen))
                os.replace(tmp, state_path)
        except urllib.error.URLError as e:
            log.warning("network error: %s", e)
        except Exception:
            log.exception("poll iteration failed")

        _sleep_unless(stop, poll)

    log.info("stopped")


if __name__ == "__main__":
    main()
