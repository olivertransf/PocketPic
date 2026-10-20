// Usage: node scripts/set-capture-dates.mjs dates.json
// dates.json maps bucket keys to ISO capture dates: { "IMG_0016.JPG": "2026-01-02T03:04:05.000Z" }
// Rewrites each object in place with customMetadata.capturedAt, then drops the photo index so the Worker rebuilds it.

import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getPlatformProxy } from "wrangler";

const datesPath = process.argv[2];
if (!datesPath) {
  console.error("Usage: node scripts/set-capture-dates.mjs dates.json");
  process.exit(1);
}

const dates = JSON.parse(readFileSync(datesPath, "utf8"));
const configDir = mkdtempSync(join(tmpdir(), "pocketpic-dates-"));
const configPath = join(configDir, "wrangler.json");
writeFileSync(configPath, JSON.stringify({
  name: "pocketpic-capture-dates",
  compatibility_date: "2026-10-19",
  r2_buckets: [{ binding: "PHOTOS", bucket_name: "pocketpic", remote: true }],
}));

const { env, dispose } = await getPlatformProxy({ configPath });
let updated = 0;
let skipped = 0;

try {
  for (const [key, value] of Object.entries(dates)) {
    const capturedAt = new Date(value);
    if (Number.isNaN(capturedAt.getTime())) {
      console.warn(`skip ${key}: bad date ${value}`);
      skipped++;
      continue;
    }

    const head = await env.PHOTOS.head(key);
    if (!head) {
      console.warn(`skip ${key}: not in bucket`);
      skipped++;
      continue;
    }
    if (head.customMetadata?.capturedAt === capturedAt.toISOString()) {
      skipped++;
      continue;
    }

    const object = await env.PHOTOS.get(key);
    await env.PHOTOS.put(key, await object.arrayBuffer(), {
      httpMetadata: object.httpMetadata,
      customMetadata: { ...object.customMetadata, capturedAt: capturedAt.toISOString() },
    });
    updated++;
    console.log(`${updated} ${key} ${capturedAt.toISOString()}`);
  }

  if (updated > 0) await env.PHOTOS.delete("index/photos.json");
  console.log(`updated ${updated}, skipped ${skipped}`);
} finally {
  await dispose();
}
