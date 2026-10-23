interface Env {
  PHOTOS: R2Bucket;
  ASSETS: Fetcher;
}

interface PhotoMeta {
  id: string;
  key: string;
  date: string;
  mimeType: string;
  width: number | null;
  height: number | null;
  size: number;
  updatedAt: string;
}

interface StoredPassphrase {
  hash: string;
  updatedAt: string;
}

const INDEX_KEY = "index/photos.json";
const AUTH_KEY = "auth/passphrase.json";
const SESSION_COOKIE = "pp_session";
const SESSION_TTL_SECONDS = 60 * 60 * 24 * 30;
const MAX_UPLOAD_BYTES = 40 * 1024 * 1024;
// How long a bucket listing is trusted before the photo index is reconciled with R2 again.
// Keeps objects added outside the app (dashboard, CLI, other tools) showing up without a list on every sync.
const INDEX_RECONCILE_MS = 2 * 60 * 1000;
const ID_PATTERN = /^[A-Za-z0-9_-]{1,100}$/;
const IMAGE_EXTENSIONS: Record<string, string> = {
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  heic: "image/heic",
  avif: "image/avif",
  gif: "image/gif",
};

const encoder = new TextEncoder();

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/")) {
      return env.ASSETS.fetch(request);
    }
    try {
      return await handleApi(request, env, url);
    } catch (error) {
      console.error(JSON.stringify({ message: "api error", path: url.pathname, error: String(error) }));
      return json({ error: "Internal error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function handleApi(request: Request, env: Env, url: URL): Promise<Response> {
  const path = url.pathname;
  const method = request.method;

  if (path === "/api/session" && method === "GET") {
    const stored = await readPassphrase(env);
    const unlocked = stored ? await isSessionValid(request, stored) : false;
    return json({ unlocked, passphraseSet: stored !== null });
  }

  if (path === "/api/unlock" && method === "POST") {
    return unlock(request, env);
  }

  if (path === "/api/lock" && method === "POST") {
    return json({ ok: true }, 200, { "Set-Cookie": clearSessionCookie() });
  }

  const stored = await readPassphrase(env);
  if (!stored || !(await isSessionValid(request, stored))) {
    return json({ error: "Locked" }, 401);
  }

  if (path === "/api/passphrase" && method === "PUT") {
    return changePassphrase(request, env);
  }

  if (path === "/api/photos" && method === "GET") {
    const rebuild = url.searchParams.has("rebuild");
    const { photos, reconciledAt } = await readIndex(env);
    const lastReconciled = reconciledAt ? Date.parse(reconciledAt) : Number.NaN;
    const stale = rebuild || !Number.isFinite(lastReconciled) || Date.now() - lastReconciled > INDEX_RECONCILE_MS;
    // The R2 bucket is the source of truth: photos uploaded outside the app still load here.
    const list = stale ? await reconcileIndexWithBucket(env) : photos;
    return json({ photos: sortNewestFirst(list) });
  }

  if (path === "/api/photos/delete" && method === "POST") {
    const body = await readJson<{ ids?: unknown }>(request);
    const ids = Array.isArray(body?.ids) ? body.ids.filter((id): id is string => typeof id === "string") : [];
    if (ids.length === 0) return json({ error: "No ids" }, 400);
    await deletePhotos(env, ids);
    return json({ ok: true });
  }

  const match = path.match(/^\/api\/photos\/([^/]+)$/);
  if (match) {
    const id = decodeURIComponent(match[1]);
    if (!ID_PATTERN.test(id)) return json({ error: "Invalid id" }, 400);
    switch (method) {
      case "GET":
        return getPhoto(request, env, id);
      case "PUT":
        return putPhoto(request, env, id);
      case "DELETE":
        await deletePhotos(env, [id]);
        return json({ ok: true });
    }
  }

  return json({ error: "Not found" }, 404);
}

async function unlock(request: Request, env: Env): Promise<Response> {
  const body = await readJson<{ passphrase?: unknown }>(request);
  const passphrase = typeof body?.passphrase === "string" ? body.passphrase.trim() : "";
  if (!passphrase) return json({ error: "Enter a passphrase." }, 400);

  const hash = await sha256Hex(passphrase);
  let stored = await readPassphrase(env);

  if (!stored) {
    stored = { hash, updatedAt: new Date().toISOString() };
    await env.PHOTOS.put(AUTH_KEY, JSON.stringify(stored), {
      httpMetadata: { contentType: "application/json" },
    });
    return json({ ok: true, created: true }, 200, { "Set-Cookie": await sessionCookie(stored) });
  }

  if (!timingSafeEqualHex(hash, stored.hash)) {
    return json({ error: "Incorrect passphrase." }, 401);
  }
  return json({ ok: true, created: false }, 200, { "Set-Cookie": await sessionCookie(stored) });
}

async function changePassphrase(request: Request, env: Env): Promise<Response> {
  const body = await readJson<{ passphrase?: unknown }>(request);
  const passphrase = typeof body?.passphrase === "string" ? body.passphrase.trim() : "";
  if (!passphrase) return json({ error: "Passphrase cannot be empty." }, 400);

  const stored: StoredPassphrase = { hash: await sha256Hex(passphrase), updatedAt: new Date().toISOString() };
  await env.PHOTOS.put(AUTH_KEY, JSON.stringify(stored), {
    httpMetadata: { contentType: "application/json" },
  });
  return json({ ok: true }, 200, { "Set-Cookie": await sessionCookie(stored) });
}

async function getPhoto(request: Request, env: Env, id: string): Promise<Response> {
  const { photos } = await readIndex(env);
  const meta = photos.find((photo) => photo.id === id);
  if (!meta) return json({ error: "Not found" }, 404);

  const object = await env.PHOTOS.get(meta.key, { onlyIf: request.headers });
  if (!object) return json({ error: "Not found" }, 404);

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Cache-Control", "private, no-cache");
  if (!headers.has("Content-Type")) headers.set("Content-Type", meta.mimeType);

  if (!("body" in object)) {
    return new Response(null, { status: 304, headers });
  }
  return new Response(object.body, { headers });
}

async function putPhoto(request: Request, env: Env, id: string): Promise<Response> {
  const contentType = (request.headers.get("Content-Type") ?? "").split(";")[0].trim().toLowerCase();
  const extension = Object.entries(IMAGE_EXTENSIONS).find(([, type]) => type === contentType)?.[0];
  if (!extension) return json({ error: "Unsupported image type" }, 415);

  const declaredLength = Number(request.headers.get("Content-Length") ?? "0");
  if (declaredLength > MAX_UPLOAD_BYTES) return json({ error: "Photo too large" }, 413);
  if (!request.body) return json({ error: "Empty body" }, 400);

  const bodyBytes = new Uint8Array(await request.arrayBuffer());
  if (bodyBytes.length > MAX_UPLOAD_BYTES) return json({ error: "Photo too large" }, 413);

  const key = `photos/${id}.${extension === "jpeg" ? "jpg" : extension}`;
  const requestedDate = parseDate(request.headers.get("X-Photo-Date"));
  const existingDate = requestedDate ? null : (await readIndex(env)).photos.find((photo) => photo.id === id)?.date;
  const exifDate = requestedDate || existingDate ? null : parseExifDate(bodyBytes);
  const capturedAt = requestedDate ?? existingDate ?? exifDate ?? new Date().toISOString();

  const object = await env.PHOTOS.put(key, bodyBytes, {
    httpMetadata: { contentType },
    customMetadata: { capturedAt },
  });

  const width = parseDimension(request.headers.get("X-Photo-Width"));
  const height = parseDimension(request.headers.get("X-Photo-Height"));
  let saved: PhotoMeta | null = null;
  let staleKey: string | null = null;

  await mutateIndex(env, (photos) => {
    const existing = photos.find((photo) => photo.id === id);
    staleKey = existing && existing.key !== key ? existing.key : null;
    saved = {
      id,
      key,
      date: capturedAt,
      mimeType: contentType,
      width,
      height,
      size: object.size,
      updatedAt: new Date().toISOString(),
    };
    return [...photos.filter((photo) => photo.id !== id), saved];
  });

  if (staleKey) await env.PHOTOS.delete(staleKey);
  return json({ photo: saved });
}

async function deletePhotos(env: Env, ids: string[]): Promise<void> {
  const wanted = new Set(ids);
  let removedKeys: string[] = [];
  await mutateIndex(env, (photos) => {
    removedKeys = photos.filter((photo) => wanted.has(photo.id)).map((photo) => photo.key);
    return photos.filter((photo) => !wanted.has(photo.id));
  });
  for (let i = 0; i < removedKeys.length; i += 1000) {
    await env.PHOTOS.delete(removedKeys.slice(i, i + 1000));
  }
}

async function readIndex(env: Env): Promise<{ photos: PhotoMeta[]; etag: string | null; reconciledAt: string | null }> {
  const object = await env.PHOTOS.get(INDEX_KEY);
  if (!object) return { photos: await scanBucketForPhotos(env), etag: null, reconciledAt: null };
  const photos = await object.json<PhotoMeta[]>();
  return {
    photos: Array.isArray(photos) ? photos : [],
    etag: object.etag,
    reconciledAt: object.customMetadata?.reconciledAt ?? null,
  };
}

// Rebuilds the index from what is actually in the bucket, so photos added outside
// the app (dashboard uploads, CLI, migrations) load in the web app.
async function reconcileIndexWithBucket(env: Env): Promise<PhotoMeta[]> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const object = await env.PHOTOS.get(INDEX_KEY);
    let indexed: PhotoMeta[] = [];
    if (object) {
      const parsed = await object.json<PhotoMeta[]>();
      indexed = Array.isArray(parsed) ? parsed : [];
    }

    const scanned = await scanBucketForPhotos(env, new Map(indexed.map((photo) => [photo.key, photo])));
    const written = await env.PHOTOS.put(INDEX_KEY, JSON.stringify(scanned), {
      httpMetadata: { contentType: "application/json" },
      customMetadata: { reconciledAt: new Date().toISOString() },
      ...(object ? { onlyIf: { etagMatches: object.etag } } : {}),
    });
    if (written || !object) return scanned;
  }

  const { photos } = await readIndex(env);
  return photos;
}

async function mutateIndex(env: Env, change: (photos: PhotoMeta[]) => PhotoMeta[]): Promise<void> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const { photos, etag } = await readIndex(env);
    const next = change(photos);
    const written = await env.PHOTOS.put(INDEX_KEY, JSON.stringify(next), {
      httpMetadata: { contentType: "application/json" },
      ...(etag ? { onlyIf: { etagMatches: etag } } : {}),
    });
    if (written) return;
  }
  throw new Error("Photo index is busy, try again");
}

async function scanBucketForPhotos(env: Env, known?: Map<string, PhotoMeta>): Promise<PhotoMeta[]> {
  const photos: PhotoMeta[] = [];
  const seen = new Set<string>();
  let cursor: string | undefined;
  do {
    const listed = await env.PHOTOS.list({ cursor, include: ["httpMetadata", "customMetadata"] });
    for (const object of listed.objects) {
      if (object.key.startsWith("index/") || object.key.startsWith("auth/")) continue;
      const extension = object.key.split(".").pop()?.toLowerCase() ?? "";
      const mimeType = IMAGE_EXTENSIONS[extension];
      if (!mimeType) continue;

      const existing = known?.get(object.key);
      const baseId = object.key.replace(/^photos\//, "").replace(/\.[^.]+$/, "").replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 100);
      let id = existing?.id ?? baseId ?? crypto.randomUUID();
      while (seen.has(id)) id = `${baseId.slice(0, 90)}_${seen.size}`;
      seen.add(id);

      let capturedAt = getCapturedAtMetadata(object.customMetadata) ?? existing?.date ?? dateFromKey(object.key);
      if (!capturedAt) {
        try {
          const header = await env.PHOTOS.get(object.key, { range: { offset: 0, length: 524288 } });
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
        width: existing?.width ?? null,
        height: existing?.height ?? null,
        size: object.size,
        updatedAt: existing?.updatedAt ?? object.uploaded.toISOString(),
      });
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  return photos;
}

function getCapturedAtMetadata(customMetadata?: Record<string, string> | null): string | null {
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

function dateFromKey(key: string): string | null {
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

function parseExifDate(arrayBuffer: ArrayBuffer | Uint8Array): string | null {
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

function parseTiffExifDate(bytes: Uint8Array, tiffOffset: number): string | null {
  if (tiffOffset + 8 > bytes.length) return null;
  const isLittleEndian = bytes[tiffOffset] === 0x49 && bytes[tiffOffset + 1] === 0x49;
  const isBigEndian = bytes[tiffOffset] === 0x4d && bytes[tiffOffset + 1] === 0x4d;
  if (!isLittleEndian && !isBigEndian) return null;

  const readUint16 = (o: number) => {
    if (o + 2 > bytes.length) return 0;
    return isLittleEndian ? bytes[o] | (bytes[o + 1] << 8) : (bytes[o] << 8) | bytes[o + 1];
  };
  const readUint32 = (o: number) => {
    if (o + 4 > bytes.length) return 0;
    return isLittleEndian
      ? (bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16) | (bytes[o + 3] << 24)) >>> 0
      : ((bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]) >>> 0;
  };

  if (readUint16(tiffOffset + 2) !== 0x002a) return null;

  const ifd0Offset = tiffOffset + readUint32(tiffOffset + 4);
  let exifSubIfdOffset: number | null = null;
  let bestDateTimeString: string | null = null;
  let bestPriority = 999;

  const readIfdTags = (ifdOffset: number) => {
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

function sortNewestFirst(photos: PhotoMeta[]): PhotoMeta[] {
  return [...photos].sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
}

async function readPassphrase(env: Env): Promise<StoredPassphrase | null> {
  const object = await env.PHOTOS.get(AUTH_KEY);
  if (!object) return null;
  const stored = await object.json<StoredPassphrase>();
  return stored && typeof stored.hash === "string" ? stored : null;
}

async function sessionCookie(stored: StoredPassphrase): Promise<string> {
  const expires = Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS;
  const signature = await hmacHex(stored.hash, `session:${expires}`);
  return `${SESSION_COOKIE}=${expires}.${signature}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_TTL_SECONDS}`;
}

function clearSessionCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`;
}

async function isSessionValid(request: Request, stored: StoredPassphrase): Promise<boolean> {
  const cookie = request.headers.get("Cookie") ?? "";
  const token = cookie
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${SESSION_COOKIE}=`))
    ?.slice(SESSION_COOKIE.length + 1);
  if (!token) return false;

  const [expiresText, signature] = token.split(".");
  const expires = Number(expiresText);
  if (!signature || !Number.isFinite(expires) || expires < Date.now() / 1000) return false;
  const expected = await hmacHex(stored.hash, `session:${expires}`);
  return timingSafeEqualHex(signature, expected);
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return toHex(digest);
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(value)));
}

function timingSafeEqualHex(a: string, b: string): boolean {
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.byteLength !== right.byteLength) return false;
  return crypto.subtle.timingSafeEqual(left, right);
}

function toHex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function parseDate(value: string | number | null | undefined): string | null {
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

function parseDimension(value: string | null): number | null {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? Math.round(number) : null;
}

async function readJson<T>(request: Request): Promise<T | null> {
  try {
    return (await request.json()) as T;
  } catch {
    return null;
  }
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });
}
