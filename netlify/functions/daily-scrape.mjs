// netlify/functions/daily-scrape.mjs — the Netlify-native daily trigger.
//
// Runs on the site's PRODUCTION deploy only (scheduled functions do not
// fire from branch deploys / deploy previews — Netlify docs, re-verified
// by the netlify-free-tier-maxxing kit r4/r19). Its ONLY job: POST the
// site's build hook with ?branch=scrape so the heavy pipeline build runs
// as a (free) branch build. Well inside the 30s scheduled-function limit.
//
// In-flight guard: 1 concurrent build per free account — if a build is
// already running (stuck or slow), skip this fire instead of piling the
// queue. The next day's fire retries; the GHA weekly cron + the standby
// watchdog remain the outer safety nets either way.
//
// Env (site-level): BUILD_HOOK_URL, NETLIFY_AUTH_TOKEN, NETLIFY_SITE_ID

export const config = { schedule: "0 4 * * *" }; // daily 04:00 UTC

const STATES_BUSY = new Set(["new", "building", "uploading", "processing"]);

export default async () => {
  const hook = process.env.BUILD_HOOK_URL;
  const token = process.env.NETLIFY_AUTH_TOKEN;
  const siteId = process.env.NETLIFY_SITE_ID;

  if (!hook) {
    console.error("[daily-scrape] BUILD_HOOK_URL not set — nothing to do");
    return new Response("BUILD_HOOK_URL not set", { status: 500 });
  }

  // ── in-flight guard ─────────────────────────────────────────────────
  if (token && siteId) {
    try {
      const res = await fetch(
        `https://api.netlify.com/api/v1/sites/${siteId}/deploys?per_page=10`,
        { headers: { Authorization: `Bearer ${token}` } },
      );
      if (res.ok) {
        const deploys = await res.json();
        const busy = (Array.isArray(deploys) ? deploys : []).filter((d) =>
          STATES_BUSY.has(d.state) || STATES_BUSY.has(d?.summary?.status),
        );
        if (busy.length > 0) {
          console.log(
            `[daily-scrape] build already in flight (id=${busy[0].id} ` +
              `state=${busy[0].state}) — skipping this fire to avoid a queue pile-up`,
          );
          return new Response("skipped: build in flight", { status: 200 });
        }
      }
    } catch (err) {
      // The guard is best-effort — a failed status check must not stop the
      // fire; the queue would just serialize behind the running build.
      console.warn(`[daily-scrape] guard check failed (continuing): ${err}`);
    }
  }

  // ── fire the scrape build (branch deploy = free) ────────────────────
  const url = hook.includes("?") ? `${hook}&branch=scrape` : `${hook}?branch=scrape`;
  try {
    const res = await fetch(url, { method: "POST" });
    console.log(`[daily-scrape] build hook fired: HTTP ${res.status} -> ${url}`);
    if (!res.ok) {
      return new Response(`build hook HTTP ${res.status}`, { status: 502 });
    }
    return new Response("build hook fired", { status: 200 });
  } catch (err) {
    console.error(`[daily-scrape] build hook POST failed: ${err}`);
    return new Response(`build hook failed: ${err}`, { status: 502 });
  }
};
