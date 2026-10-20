# Update-check server

A Cloudflare Worker with a D1 database. It answers the app's daily, opt-in
update check and counts active installs.

## What it stores

One row per install per day: the date, a random install ID (a UUID the app
creates when you allow update checks), the app version and the macOS version.
IP addresses and account data are never stored. A daily cron deletes rows older
than 90 days.

## Endpoints

| Path | Returns |
|---|---|
| `GET /v1/check?id=&v=&os=` | `{"latest": "0.1.0", "url": "…"}` and records the ping |
| `GET /v1/stats` | Daily, weekly and monthly active installs and the version mix |
| `GET /v1/badge` | A [shields.io endpoint](https://shields.io/badges/endpoint-badge) badge with weekly active installs |

The latest version comes from the redirect behind
`github.com/nxm/aqara-doorbell/releases/latest`, cached in D1 for an hour.

## Deploy

```sh
cd server
npx wrangler login                     # or: nix run nixpkgs#wrangler -- …
npx wrangler d1 create aqara-doorbell  # put the printed database_id in wrangler.toml
npx wrangler d1 execute aqara-doorbell --remote --file schema.sql
npx wrangler deploy
```

If you run your own copy, point `UpdateChecker.endpoint` in the app at it.
