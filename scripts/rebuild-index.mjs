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

      let capturedAt = getCapturedAtMetadata(object.customMetadata);
      let dateSource = capturedAt ? "metadata" : null;
      if (!capturedAt) {
        capturedAt = dateFromKey(object.key);
        if (capturedAt) dateSource = "filename";
      }
      if (!capturedAt) {
        try {
          const header = await env.PHOTOS.get(object.key, { range: { offset: 0, length: 524288 } });
          if (header) {
            const buf = new Uint8Array(await header.arrayBuffer());
            capturedAt = parseExifDate(buf);
            if (capturedAt) dateSource = "exif";
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
        dateSource: dateSource ?? "uploaded",
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
    const cleanKey = key.toLowerCase().replace(/^x-amz-meta-|^x-goog-meta-/, "").trim();
    if (
      cleanKey === "capturedat" ||
      cleanKey === "captured_at" ||
      cleanKey === "captured-at" ||
      cleanKey === "capturedate" ||
      cleanKey === "capture_date" ||
      cleanKey === "date" ||
      cleanKey === "x-photo-date" ||
      cleanKey === "photo_date" ||
      cleanKey === "photodate" ||
      cleanKey === "photo-date" ||
      cleanKey === "picture_date" ||
      cleanKey === "picturedate" ||
      cleanKey === "exif_date" ||
      cleanKey === "exifdate" ||
      cleanKey === "exif-date" ||
      cleanKey === "createdat" ||
      cleanKey === "created_at" ||
      cleanKey === "creationdate" ||
      cleanKey === "creation_date" ||
      cleanKey === "date_taken" ||
      cleanKey === "datetaken" ||
      cleanKey === "timestamp" ||
      cleanKey === "datetimeoriginal" ||
      cleanKey === "date-time-original" ||
      cleanKey === "datetime_original" ||
      cleanKey === "datetime" ||
      cleanKey === "created" ||
      cleanKey === "date_created" ||
      cleanKey === "datecreated" ||
      cleanKey === "originationdate" ||
      cleanKey === "time"
    ) {
      const parsed = parseDate(value);
      if (parsed) return parsed;
    }
  }
  return null;
}

function dateFromKey(key) {
  let filename = key.split("/").pop() ?? key;
  try {
    filename = decodeURIComponent(filename);
  } catch {
    // ignore decode error
  }

  const stem = filename.replace(/\.[^.]+$/, "");
  if (
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(stem) ||
    /^[0-9a-f]{32}$/i.test(stem)
  ) {
    return null;
  }

  const fullDateTimeIso = filename.match(/(19\d{2}|20\d{2})[-_./](0[1-9]|1[0-2])[-_./](0[1-9]|[12]\d|3[01])[-_T\s]([01]\d|2[0-3])[:_.-]([0-5]\d)[:_.-]([0-5]\d)(?:[:_.-](\d{1,3}))?\s*(Z|[+-]\d{2}:?\d{2})?/i);
  if (fullDateTimeIso) {
    const [, y, m, d, hh, mm, ss, ms, tz] = fullDateTimeIso;
    let isoStr = `${y}-${m}-${d}T${hh}:${mm}:${ss}`;
    if (ms) isoStr += `.${ms.padStart(3, "0")}`;
    if (tz) isoStr += tz;
    else isoStr += "Z";
    return parseDate(isoStr);
  }

  const fullDateTimeCompact = filename.match(/(19\d{2}|20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])[-_T\s]?([01]\d|2[0-3])([0-5]\d)([0-5]\d)/);
  if (fullDateTimeCompact) {
    const [, y, m, d, hh, mm, ss] = fullDateTimeCompact;
    return parseDate(`${y}-${m}-${d}T${hh}:${mm}:${ss}Z`);
  }

  const isoDate = filename.match(/(19\d{2}|20\d{2})[-_./](0[1-9]|1[0-2])[-_./](0[1-9]|[12]\d|3[01])/);
  if (isoDate) {
    return parseDate(`${isoDate[1]}-${isoDate[2]}-${isoDate[3]}T12:00:00Z`);
  }

  const usDate = filename.match(/(0[1-9]|1[0-2])[-_./](0[1-9]|[12]\d|3[01])[-_./](19\d{2}|20\d{2})/);
  if (usDate) {
    return parseDate(`${usDate[3]}-${usDate[1]}-${usDate[2]}T12:00:00Z`);
  }

  const compactDate = filename.match(/(19\d{2}|20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])/);
  if (compactDate) {
    return parseDate(`${compactDate[1]}-${compactDate[2]}-${compactDate[3]}T12:00:00Z`);
  }

  // Do not match timestamp numbers if stem contains hex/alphanumeric mix (e.g. UUID fragments)
  if (/[a-zA-Z]/.test(stem)) return null;

  const millis = filename.match(/(?:^|[^0-9])([12]\d{12})(?:[^0-9]|$)/);
  if (millis) return parseDate(Number(millis[1]));

  const seconds = filename.match(/(?:^|[^0-9])([12]\d{9})(?:[^0-9]|$)/);
  if (seconds) return parseDate(Number(seconds[1]) * 1000);

  return null;
}

function parseExifDate(arrayBuffer) {
  const bytes = arrayBuffer instanceof Uint8Array ? arrayBuffer : new Uint8Array(arrayBuffer);
  if (bytes.length < 14) return null;

  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
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
          const res = parseTiffExifDate(bytes, app1Offset + 6);
          if (res) return res;
        }
        const directTiff = parseTiffExifDate(bytes, app1Offset);
        if (directTiff) return directTiff;
      }
      offset += 2 + length;
    }
  }

  if (
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50
  ) {
    let offset = 12;
    while (offset < bytes.length - 8) {
      const chunkType = String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
      const chunkSize = (bytes[offset + 4] | (bytes[offset + 5] << 8) | (bytes[offset + 6] << 16) | (bytes[offset + 7] << 24)) >>> 0;
      const payloadOffset = offset + 8;
      if (chunkType === "EXIF" && payloadOffset < bytes.length) {
        if (
          payloadOffset + 6 <= bytes.length &&
          bytes[payloadOffset] === 0x45 && bytes[payloadOffset + 1] === 0x78 &&
          bytes[payloadOffset + 2] === 0x69 && bytes[payloadOffset + 3] === 0x66
        ) {
          const res = parseTiffExifDate(bytes, payloadOffset + 6);
          if (res) return res;
        }
        return parseTiffExifDate(bytes, payloadOffset);
      }
      offset += 8 + chunkSize + (chunkSize % 2);
    }
  }

  if (
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) {
    let offset = 8;
    while (offset < bytes.length - 8) {
      const chunkSize = ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
      const chunkType = String.fromCharCode(bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7]);
      const payloadOffset = offset + 8;

      if (chunkType === "eXIf" && payloadOffset < bytes.length) {
        const res = parseTiffExifDate(bytes, payloadOffset);
        if (res) return res;
      } else if (chunkType === "tIME" && payloadOffset + 7 <= bytes.length) {
        const year = (bytes[payloadOffset] << 8) | bytes[payloadOffset + 1];
        const month = bytes[payloadOffset + 2];
        const day = bytes[payloadOffset + 3];
        const hour = bytes[payloadOffset + 4];
        const minute = bytes[payloadOffset + 5];
        const second = bytes[payloadOffset + 6];
        const iso = `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:${String(second).padStart(2, "0")}Z`;
        const res = parseDate(iso);
        if (res) return res;
      } else if ((chunkType === "tEXt" || chunkType === "iTXt") && payloadOffset + chunkSize <= bytes.length) {
        let keyword = "";
        let kOffset = payloadOffset;
        while (kOffset < payloadOffset + chunkSize && bytes[kOffset] !== 0) {
          keyword += String.fromCharCode(bytes[kOffset]);
          kOffset++;
        }
        const cleanKw = keyword.toLowerCase().trim();
        if (cleanKw.includes("creation") || cleanKw.includes("date") || cleanKw.includes("time")) {
          let textVal = "";
          for (let p = kOffset + 1; p < payloadOffset + chunkSize; p++) {
            if (bytes[p] === 0) continue;
            textVal += String.fromCharCode(bytes[p]);
          }
          const res = parseDate(textVal);
          if (res) return res;
        }
      }
      offset += 12 + chunkSize;
    }
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
  let bestDateTimeString = null;
  let bestPriority = 999;

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
        const priority = tag === 0x9003 ? 1 : tag === 0x9004 ? 2 : 3;
        if (type === 2 && priority < bestPriority) {
          const stringOffset = count > 4 ? tiffOffset + readUint32(valueOffset) : valueOffset;
          if (stringOffset + count <= bytes.length) {
            let str = "";
            for (let c = 0; c < count; c++) {
              const ch = bytes[stringOffset + c];
              if (ch === 0) break;
              str += String.fromCharCode(ch);
            }
            if (str.trim()) {
              bestDateTimeString = str;
              bestPriority = priority;
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

  if (bestDateTimeString) {
    return parseDate(bestDateTimeString);
  }
  return null;
}

function parseDate(value) {
  if (value === null || value === undefined || value === "") return null;

  if (typeof value === "number") {
    if (!Number.isFinite(value) || value <= 0) return null;
    const ms = value < 1e11 ? value * 1000 : value;
    const d = new Date(ms);
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }

  let str = String(value).replace(/\0/g, "").trim();
  if (!str) return null;

  if (/^\d{9,13}$/.test(str)) {
    const num = Number(str);
    if (Number.isFinite(num) && num > 0) {
      const ms = num < 1e11 ? num * 1000 : num;
      const d = new Date(ms);
      if (!Number.isNaN(d.getTime())) return d.toISOString();
    }
  }

  const directParsed = Date.parse(str);
  if (!Number.isNaN(directParsed) && str.includes("-") && (str.includes("T") || str.includes(" "))) {
    return new Date(directParsed).toISOString();
  }

  const exifMatch = str.match(/^(19\d{2}|20\d{2})[:/-](0[1-9]|1[0-2])[:/-](0[1-9]|[12]\d|3[01])[\sT_]?([01]\d|2[0-3])?[:_.-]?([0-5]\d)?[:_.-]?([0-5]\d)?(.*)$/);
  if (exifMatch) {
    const [, y, m, d, hh = "12", mm = "00", ss = "00", tz = ""] = exifMatch;
    let isoCandidate = `${y}-${m}-${d}T${hh}:${mm}:${ss}`;
    const cleanTz = tz.trim();
    if (cleanTz && /^(Z|[+-]\d{2}:?\d{2})$/i.test(cleanTz)) {
      isoCandidate += cleanTz;
    } else {
      isoCandidate += "Z";
    }
    const parsedExif = Date.parse(isoCandidate);
    if (!Number.isNaN(parsedExif)) return new Date(parsedExif).toISOString();
  }

  const bareIso = str.match(/^(19\d{2}|20\d{2})[-_./](0[1-9]|1[0-2])[-_./](0[1-9]|[12]\d|3[01])$/);
  if (bareIso) {
    return new Date(`${bareIso[1]}-${bareIso[2]}-${bareIso[3]}T12:00:00Z`).toISOString();
  }

  const time = Date.parse(str);
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
