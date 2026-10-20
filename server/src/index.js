// Update check and anonymous active-install counter for the Aqara Doorbell app.
//
// The app calls /v1/check at most once a day, and only after the user opts in.
// Stored per day: a random install id, the app version and the macOS version.
// No IP addresses, no account data. Rows older than 90 days are deleted daily.

const REPO = "nxm/aqara-doorbell";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHORT = /^[0-9A-Za-z.+_-]{1,32}$/;

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET") return new Response("method not allowed", { status: 405 });
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/v1/check":
        return check(url, env, ctx);
      case "/v1/stats":
        return json(await stats(env), 300);
      case "/v1/badge": {
        // shields.io endpoint badge: https://img.shields.io/endpoint?url=<this>
        const { weekly } = await stats(env);
        return json({ schemaVersion: 1, label: "weekly active installs", message: String(weekly), color: "blue" }, 900);
      }
      default:
        return new Response("not found", { status: 404 });
    }
  },

  async scheduled(_event, env) {
    await env.DB.prepare("DELETE FROM pings WHERE day < date('now', '-90 days')").run();
  },
};

async function check(url, env, ctx) {
  const id = url.searchParams.get("id") ?? "";
  const version = url.searchParams.get("v") ?? "";
  const os = url.searchParams.get("os") ?? "";
  if (UUID.test(id) && SHORT.test(version) && SHORT.test(os)) {
    ctx.waitUntil(
      env.DB.prepare(
        "INSERT INTO pings (day, install_id, version, os) VALUES (date('now'), ?1, ?2, ?3) " +
          "ON CONFLICT (day, install_id) DO UPDATE SET version = excluded.version, os = excluded.os",
      )
        .bind(id.toLowerCase(), version, os)
        .run(),
    );
  }
  const latest = await latestRelease(env);
  return json(latest ?? {}, 0);
}

// github.com/<repo>/releases/latest redirects to the newest tag. Reading that
// redirect avoids the GitHub API's per-IP rate limit; the result is cached in
// D1 for an hour (the Cache API does nothing on workers.dev).
async function latestRelease(env) {
  const cached = await env.DB.prepare(
    "SELECT value FROM meta WHERE key = 'latest' AND updated > datetime('now', '-1 hour')",
  ).first("value");
  if (cached) return JSON.parse(cached);

  const res = await fetch(`https://github.com/${REPO}/releases/latest`, { redirect: "manual" });
  const location = res.headers.get("location") ?? "";
  const match = location.match(/\/releases\/tag\/v?([^/?#]+)$/);
  if (!match) return null;
  const latest = { latest: match[1], url: location };
  await env.DB.prepare(
    "INSERT INTO meta (key, value, updated) VALUES ('latest', ?1, datetime('now')) " +
      "ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated = excluded.updated",
  )
    .bind(JSON.stringify(latest))
    .run();
  return latest;
}

async function stats(env) {
  const count = (since) =>
    env.DB.prepare(`SELECT COUNT(DISTINCT install_id) AS n FROM pings WHERE day > date('now', '${since}')`).first("n");
  const [daily, weekly, monthly] = await Promise.all([count("-1 day"), count("-7 days"), count("-30 days")]);
  const { results: versions } = await env.DB.prepare(
    "SELECT version, COUNT(DISTINCT install_id) AS installs FROM pings " +
      "WHERE day > date('now', '-7 days') GROUP BY version ORDER BY installs DESC",
  ).all();
  return { daily, weekly, monthly, versions };
}

function json(body, maxAge) {
  return new Response(JSON.stringify(body), {
    headers: {
      "content-type": "application/json",
      "cache-control": `public, max-age=${maxAge}`,
      "access-control-allow-origin": "*",
    },
  });
}
