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
    const { photos } = await readIndex(env);
    return json({ photos: sortNewestFirst(photos) });
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

  const key = `photos/${id}.${extension === "jpeg" ? "jpg" : extension}`;
  const object = await env.PHOTOS.put(key, request.body, {
    httpMetadata: { contentType },
  });
  if (object.size > MAX_UPLOAD_BYTES) {
    await env.PHOTOS.delete(key);
    return json({ error: "Photo too large" }, 413);
  }

  const requestedDate = parseDate(request.headers.get("X-Photo-Date"));
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
      date: requestedDate ?? existing?.date ?? new Date().toISOString(),
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

async function readIndex(env: Env): Promise<{ photos: PhotoMeta[]; etag: string | null }> {
  const object = await env.PHOTOS.get(INDEX_KEY);
  if (!object) return { photos: await scanBucketForPhotos(env), etag: null };
  const photos = await object.json<PhotoMeta[]>();
  return { photos: Array.isArray(photos) ? photos : [], etag: object.etag };
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

async function scanBucketForPhotos(env: Env): Promise<PhotoMeta[]> {
  const photos: PhotoMeta[] = [];
  const seen = new Set<string>();
  let cursor: string | undefined;
  do {
    const listed = await env.PHOTOS.list({ cursor, include: ["httpMetadata"] });
    for (const object of listed.objects) {
      if (object.key.startsWith("index/") || object.key.startsWith("auth/")) continue;
      const extension = object.key.split(".").pop()?.toLowerCase() ?? "";
      const mimeType = IMAGE_EXTENSIONS[extension];
      if (!mimeType) continue;

      const baseId = object.key.replace(/^photos\//, "").replace(/\.[^.]+$/, "").replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 100);
      let id = baseId || crypto.randomUUID();
      while (seen.has(id)) id = `${baseId.slice(0, 90)}_${seen.size}`;
      seen.add(id);

      photos.push({
        id,
        key: object.key,
        date: dateFromKey(object.key) ?? object.uploaded.toISOString(),
        mimeType: object.httpMetadata?.contentType ?? mimeType,
        width: null,
        height: null,
        size: object.size,
        updatedAt: object.uploaded.toISOString(),
      });
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  return photos;
}

function dateFromKey(key: string): string | null {
  const filename = key.split("/").pop() ?? key;
  const iso = filename.match(/(20\d{2})[-_](0[1-9]|1[0-2])[-_](0[1-9]|[12]\d|3[01])/);
  if (iso) return new Date(`${iso[1]}-${iso[2]}-${iso[3]}T12:00:00Z`).toISOString();
  const compact = filename.match(/(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])/);
  if (compact) return new Date(`${compact[1]}-${compact[2]}-${compact[3]}T12:00:00Z`).toISOString();
  const millis = filename.match(/\b(1[6-9]\d{11})\b/);
  if (millis) return new Date(Number(millis[1])).toISOString();
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

function parseDate(value: string | null): string | null {
  if (!value) return null;
  const time = Date.parse(value);
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
