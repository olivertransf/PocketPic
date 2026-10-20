import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getPlatformProxy } from "wrangler";

const IMAGE_EXTENSIONS = {
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  heic: "image/heic",
  avif: "image/avif",
  gif: "image/gif",
};

export async function rebuildBucketIndex(env) {
  const photos = [];
  const seen = new Set();
  let cursor;

  do {
    const listed = await env.PHOTOS.list({ cursor, include: ["httpMetadata", "customMetadata"] });
    for (const object of listed.objects) {
      if (object.key.startsWith("index/") || object.key.startsWith("auth/")) continue;
      const extension = object.key.split(".").pop()?.toLowerCase() ?? "";
      const mimeType = IMAGE_EXTENSIONS[extension];
      if (!mimeType) continue;

      const baseId = object.key.replace(/^photos\//, "").replace(/\.[^.]+$/, "").replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 100);
      let id = baseId || crypto.randomUUID();
      while (seen.has(id)) id = `${baseId.slice(0, 90)}_${seen.size}`;
      seen.add(id);

      let capturedAt = getCapturedAtMetadata(object.customMetadata) ?? dateFromKey(object.key);
      if (!capturedAt) {
        try {
          const header = await env.PHOTOS.get(object.key, { range: { length: 65536 } });
          if (header) {
            const buf = new Uint8Array(await header.arrayBuffer());
            capturedAt = parseExifDate(buf);
          }
        } catch {
          // ignore EXIF parse failure
        }
      }
      const date = capturedAt ?? object.uploaded.toISOString();

      photos.push({
        id,
        key: object.key,
        date,
        mimeType: object.httpMetadata?.contentType ?? mimeType,
        width: null,
        height: null,
        size: object.size,
        updatedAt: object.uploaded.toISOString(),
      });
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);

  photos.sort((a, b) => Date.parse(b.date) - Date.parse(a.date));

  await env.PHOTOS.put("index/photos.json", JSON.stringify(photos), {
    httpMetadata: { contentType: "application/json" },
  });

  return photos;
}

function getCapturedAtMetadata(customMetadata) {
  if (!customMetadata) return null;
  for (const [key, value] of Object.entries(customMetadata)) {
    const lowerKey = key.toLowerCase();
    if (
      lowerKey === "capturedat" ||
      lowerKey === "captured_at" ||
      lowerKey === "captured-at" ||
      lowerKey === "date" ||
      lowerKey === "x-photo-date"
    ) {
      const parsed = parseDate(value);
      if (parsed) return parsed;
    }
  }
  return null;
}

function dateFromKey(key) {
  const filename = key.split("/").pop() ?? key;

  const fullDateTimeIso = filename.match(/(20\d{2})[-_](0[1-9]|1[0-2])[-_](0[1-9]|[12]\d|3[01])[-_T\s]([01]\d|2[0-3])[:_-]([0-5]\d)[:_-]([0-5]\d)/);
  if (fullDateTimeIso) {
    const [, y, m, d, hh, mm, ss] = fullDateTimeIso;
    return parseDate(`${y}-${m}-${d}T${hh}:${mm}:${ss}Z`);
  }

  const fullDateTimeCompact = filename.match(/(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])[-_T\s]?([01]\d|2[0-3])([0-5]\d)([0-5]\d)/);
  if (fullDateTimeCompact) {
    const [, y, m, d, hh, mm, ss] = fullDateTimeCompact;
    return parseDate(`${y}-${m}-${d}T${hh}:${mm}:${ss}Z`);
  }

  const isoDate = filename.match(/(20\d{2})[-_](0[1-9]|1[0-2])[-_](0[1-9]|[12]\d|3[01])/);
  if (isoDate) {
    return parseDate(`${isoDate[1]}-${isoDate[2]}-${isoDate[3]}T12:00:00Z`);
  }

  const compactDate = filename.match(/(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])/);
  if (compactDate) {
    return parseDate(`${compactDate[1]}-${compactDate[2]}-${compactDate[3]}T12:00:00Z`);
  }

  const millis = filename.match(/(?:^|[^0-9])([12]\d{12})(?:[^0-9]|$)/);
  if (millis) return parseDate(Number(millis[1]));

  const seconds = filename.match(/(?:^|[^0-9])([12]\d{9})(?:[^0-9]|$)/);
  if (seconds) return parseDate(Number(seconds[1]) * 1000);

  return null;
}

function parseExifDate(arrayBuffer) {
  const bytes = arrayBuffer instanceof Uint8Array ? arrayBuffer : new Uint8Array(arrayBuffer);
  if (bytes.length < 14) return null;

  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;

  let offset = 2;
  while (offset < bytes.length - 4) {
    if (bytes[offset] !== 0xff) break;
    const marker = bytes[offset + 1];
    if (marker === 0xda || marker === 0xd9) break;

    const length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (marker === 0xe1) {
      const app1Offset = offset + 4;
      if (
        app1Offset + 6 <= bytes.length &&
        bytes[app1Offset] === 0x45 &&
        bytes[app1Offset + 1] === 0x78 &&
        bytes[app1Offset + 2] === 0x69 &&
        bytes[app1Offset + 3] === 0x66 &&
        bytes[app1Offset + 4] === 0x00 &&
        bytes[app1Offset + 5] === 0x00
      ) {
        const tiffOffset = app1Offset + 6;
        return parseTiffExifDate(bytes, tiffOffset);
      }
    }
    offset += 2 + length;
  }
  return null;
}

function parseTiffExifDate(bytes, tiffOffset) {
  if (tiffOffset + 8 > bytes.length) return null;
  const isLittleEndian = bytes[tiffOffset] === 0x49 && bytes[tiffOffset + 1] === 0x49;
  const isBigEndian = bytes[tiffOffset] === 0x4d && bytes[tiffOffset + 1] === 0x4d;
  if (!isLittleEndian && !isBigEndian) return null;

  const readUint16 = (o) => {
    if (o + 2 > bytes.length) return 0;
    return isLittleEndian ? bytes[o] | (bytes[o + 1] << 8) : (bytes[o] << 8) | bytes[o + 1];
  };
  const readUint32 = (o) => {
    if (o + 4 > bytes.length) return 0;
    return isLittleEndian
      ? (bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16) | (bytes[o + 3] << 24)) >>> 0
      : ((bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]) >>> 0;
  };

  if (readUint16(tiffOffset + 2) !== 0x002a) return null;

  const ifd0Offset = tiffOffset + readUint32(tiffOffset + 4);
  let exifSubIfdOffset = null;
  let dateTimeString = null;

  const readIfdTags = (ifdOffset) => {
    if (ifdOffset + 2 > bytes.length) return;
    const tagCount = readUint16(ifdOffset);
    let entryOffset = ifdOffset + 2;

    for (let i = 0; i < tagCount; i++) {
      if (entryOffset + 12 > bytes.length) break;
      const tag = readUint16(entryOffset);
      const type = readUint16(entryOffset + 2);
      const count = readUint32(entryOffset + 4);
      const valueOffset = entryOffset + 8;

      if (tag === 0x8769) {
        exifSubIfdOffset = tiffOffset + readUint32(valueOffset);
      } else if (tag === 0x9003 || tag === 0x9004 || tag === 0x0132) {
        if (type === 2) {
          const stringOffset = count > 4 ? tiffOffset + readUint32(valueOffset) : valueOffset;
          if (stringOffset + count <= bytes.length) {
            let str = "";
            for (let c = 0; c < count; c++) {
              const ch = bytes[stringOffset + c];
              if (ch === 0) break;
              str += String.fromCharCode(ch);
            }
            if (!dateTimeString || tag === 0x9003) {
              dateTimeString = str;
            }
          }
        }
      }
      entryOffset += 12;
    }
  };

  readIfdTags(ifd0Offset);
  if (exifSubIfdOffset !== null) {
    readIfdTags(exifSubIfdOffset);
  }

  if (dateTimeString) {
    const match = dateTimeString.trim().match(/^(20\d{2})[:/-](0[1-9]|1[0-2])[:/-](0[1-9]|[12]\d|3[01])\s+([01]\d|2[0-3]):([0-5]\d):([0-5]\d)$/);
    if (match) {
      const iso = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}Z`;
      return parseDate(iso);
    }
  }
  return null;
}

function parseDate(value) {
  if (!value) return null;
  const time = typeof value === "number" ? value : Date.parse(value);
  return Number.isNaN(time) ? null : new Date(time).toISOString();
}

async function main() {
  const configDir = mkdtempSync(join(tmpdir(), "pocketpic-rebuild-"));
  const configPath = join(configDir, "wrangler.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      name: "pocketpic-rebuild-index",
      compatibility_date: "2026-10-19",
      r2_buckets: [{ binding: "PHOTOS", bucket_name: "pocketpic", remote: true }],
    })
  );

  const { env, dispose } = await getPlatformProxy({ configPath });

  try {
    console.log("Scanning R2 bucket photos and rebuilding index/photos.json...");
    const photos = await rebuildBucketIndex(env);
    console.log(`Successfully rebuilt index/photos.json with ${photos.length} photos.`);
  } catch (err) {
    console.error("Error rebuilding index:", err);
    process.exitCode = 1;
  } finally {
    await dispose();
  }
}

if (process.argv[1] && process.argv[1].endsWith("rebuild-index.mjs")) {
  main();
}
