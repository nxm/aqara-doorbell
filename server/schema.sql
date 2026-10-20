-- One row per install per day. No IP addresses or account data are stored.
CREATE TABLE IF NOT EXISTS pings (
  day        TEXT NOT NULL,   -- YYYY-MM-DD (UTC)
  install_id TEXT NOT NULL,   -- random UUID made by the app on opt-in
  version    TEXT NOT NULL,   -- app version
  os         TEXT NOT NULL,   -- macOS version
  PRIMARY KEY (day, install_id)
);

-- Small cache for the latest release tag.
CREATE TABLE IF NOT EXISTS meta (
  key     TEXT PRIMARY KEY,
  value   TEXT NOT NULL,
  updated TEXT NOT NULL
);
