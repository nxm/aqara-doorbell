# Aqara Doorbell notifier

Polls the Aqara event-history RPC and posts each new motion event to a Matrix
room: the snapshot as `m.image`, then the clip as an `m.video` thread reply.
Stdlib only, except `cryptography` for AES/RSA.

## Configuration (environment)

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `AQARA_EMAIL` / `AQARA_PASSWORD` | yes | — | The account that owns the camera. |
| `MATRIX_USER` / `MATRIX_PASSWORD` | yes* | — | The bot account. |
| `MATRIX_TOKEN` | — | — | Use instead of user/password. |
| `MATRIX_ROOM` | yes | — | `!roomid` — for a v12 room this has **no** `:server` suffix. |
| `MATRIX_HOMESERVER` | yes | placeholder | Set it. The NixOS module defaults to `http://127.0.0.1:8008`. Prefer a local address, because edge proxies often return 403 for `POST /login`. |
| `AQARA_HOST` | — | `https://rpc-ger.aqara.com` | Your account's regional host. |
| `AQARA_POSITION_ID` / `AQARA_DID` | — | auto | Discovered from the account when unset. |
| `POLL_INTERVAL` | — | `15` | Seconds between polls. |
| `STATE_DIR` | — | `$STATE_DIRECTORY` or `.` | Holds `last_trigger.txt` + `matrix_token.txt`. |

\* either `MATRIX_TOKEN`, or `MATRIX_USER` + `MATRIX_PASSWORD`.

## Prerequisites

- A Matrix account for the bot, joined (or invited) to the target room. The
  daemon auto-accepts the invite on start.
- Reach Synapse without the edge proxy (localhost on the homeserver box, or a
  tailnet address). Cloudflare & friends 403 `POST /_matrix/client/v3/login`.

## Run

```sh
# via the flake
nix run .#notifier

# or directly
python3 aqara_doorbell_notify.py   # needs the `cryptography` package
```

## NixOS

`module.nix` exposes `services.aqara-doorbell` (see the repo README). It runs a
hardened `DynamicUser` systemd service and reads every secret from
`environmentFile`.

## How it works

1. Log in to Aqara: `password = base64(RSA_PKCS1(md5hex(password)))`; every
   request is signed `MD5("Appid=..&Nonce=..&Time=..[&Token=..][&body]&appKey")`.
2. Poll `camera/video/intelligent/query` for the home; each event carries its
   snapshot/clip names, bucket, and short-lived COS (Tencent S3) STS creds.
3. Download the object via AWS SigV4 and decrypt it: AES-128-CBC, key =
   `bytes.fromhex(event.key)`, fixed IV, PKCS#7. Snapshots are JPEG, clips MP4.
4. Upload to Matrix and post `m.image` + a threaded `m.video`.
