# Protocol notes

What the app and the notifier speak, as reverse-engineered from the official
Aqara Home app for interoperability. Everything here talks to **your own**
account only. Aqara can change any of it without notice.

## Cloud hosts

The app cloud is regional, and an account lives in exactly one region. All
regions share the same app id and app key (see `AqaraCloud.swift`).

| Region | Host |
|---|---|
| Europe | `https://rpc-ger.aqara.com` |
| United States | `https://aiot-rpc-usa.aqara.com` |
| China | `https://aiot-rpc.aqara.cn` |
| Russia | `https://rpc-ru.aqara.com` |
| Korea / Japan | `https://rpc-kr.aqara.com` |
| Australia / SE Asia | `https://rpc-au.aqara.com` |

## Request signing

Every request carries `Appid`, `Nonce`, `Time` (ms), `Sign`, `Area`, `Lang`
headers, plus `Token` and `Userid` once logged in.

```
Sign = md5hex("Appid=<id>&Nonce=<n>&Time=<t>[&Token=<token>][&<signBody>]&<appKey>")
```

The auth fields keep that fixed order. `signBody` depends on the method:

- **GET**: the query parameters sorted by key, as raw `k=v` pairs joined with `&`.
- **POST**: the exact JSON body string that is sent.

A wrong signature returns `code: 106 "Invalid sign"`.

## Login

`POST /app/v1.0/lumi/user/login` with the body:

```json
{ "account": "<email>", "encryptType": 2, "password": "<enc>" }
```

`enc = base64(RSA_PKCS1v1.5(md5hex(password)))`, using the RSA-1024 public key
embedded in the app. The response carries `result.token`, a JWT whose `sub` is
the user id.

## Devices, homes and events

| Call | Path |
|---|---|
| Devices | `GET /app/v1.0/lumi/app/position/device/query` |
| Homes | `GET /app/v1.0/lumi/app/position/query/home/list` |
| Event history | `GET /app/v1.0/lumi/devex/camera/video/intelligent/query` |
| Status (battery, Wi-Fi) | `POST /app/v1.0/lumi/res/query` |

Event history wants the **home-level** `positionId` (`real1.*`, from the home
list), not the device's room position (`real2.*`). Asking for a position the
account does not own returns `code: 710 "Position permission denied"`.

Each item of `result.cameraFileList` has `snapshotName`, `videoName`, `path`,
`bucket`, `key`, `triggerTime`, `isSliced` and short-lived storage credentials
in `awsStsFile` (or the response-wide `defaultAwsStsFile`).

## Event media

Snapshots and clips live in Tencent COS, which speaks the S3 API:

1. The object key is `path + snapshotName` (or `+ videoName`).
2. `GET` it with AWS SigV4, signing with the STS key pair and sending
   `x-amz-security-token`.
3. Decrypt with **AES-128-CBC**: the key is `bytes.fromhex(event.key)`, the IV is
   a fixed 16-byte constant (`MEDIA_IV` in the notifier), and the padding is PKCS#7.

The result is a JPEG snapshot or an MP4 clip (it starts with an `ftyp` box).
`isSliced` events are segmented rather than one MP4, and both tools skip them.

## Live view and talkback

1. `GET /app/v1.0/lumi/devex/camera/p2p/info` returns the device's P2P id and an
   encoded init string, which decodes to the relay master servers and a key.
2. The app makes an ephemeral **X25519** key pair, and
   `POST /app/v1.0/lumi/devex/camera/p2p/sign` has the cloud sign its public key.
3. A PPCS/TUTK-style UDP session runs over the LAN or through the relays: the
   master servers return camera endpoints, then the client punches through.
4. Message `0x1000` logs in with the cloud signature and the app's public key.
   `0x1001` acknowledges, then `0x101C` starts the stream, `0x1002`/`0x1003` open
   the session, and `0x1018` asks for a keyframe.
5. The frame key is `HSalsa20(X25519(appPrivate, devicePublic))`, with no HKDF.
   Frames are **ChaCha20**-encrypted Annex-B H.264 or HEVC, decoded with
   VideoToolbox.
6. Talkback (`0x100A` to start, `0x100C` to stop) sends AAC-LC audio at 16 kHz,
   mono. `0x100E` switches the quality channel, and `0x1004` ends the session so
   the battery doorbell can go back to sleep.
