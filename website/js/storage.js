//
// Storage module for PocketPic Web
// IndexedDB is the primary per-device storage.
// Cloudflare R2 (via public bucket URL) provides shared remote sync when available.
//

const PHOTO_ID_PATTERN = /^[A-Za-z0-9_-]{1,100}$/;

class LockedError extends Error {
  constructor() {
    super('Locked');
    this.name = 'LockedError';
  }
}

function parseDateString(value) {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || value <= 0) return null;
    const ms = value < 1e11 ? value * 1000 : value;
    const d = new Date(ms);
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }
  const str = String(value).replace(/\0/g, '').trim();
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
  if (!Number.isNaN(directParsed) && str.includes('-') && (str.includes('T') || str.includes(' '))) {
    return new Date(directParsed).toISOString();
  }

  const exifMatch = str.match(/^(19\d{2}|20\d{2})[:/-](0[1-9]|1[0-2])[:/-](0[1-9]|[12]\d|3[01])[\sT_]?([01]\d|2[0-3])?[:_.-]?([0-5]\d)?[:_.-]?([0-5]\d)?(.*)$/);
  if (exifMatch) {
    const [, y, m, d, hh = '12', mm = '00', ss = '00', tz = ''] = exifMatch;
    let isoCandidate = `${y}-${m}-${d}T${hh}:${mm}:${ss}`;
    const cleanTz = tz.trim();
    if (cleanTz && /^(Z|[+-]\d{2}:?\d{2})$/i.test(cleanTz)) {
      isoCandidate += cleanTz;
    } else {
      isoCandidate += 'Z';
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

function dateFromFilename(filename) {
  if (!filename) return null;
  let cleanName = filename.split('/').pop() ?? filename;
  try {
    cleanName = decodeURIComponent(cleanName);
  } catch {}

  const stem = cleanName.replace(/\.[^.]+$/, '');
  if (
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(stem) ||
    /^[0-9a-f]{32}$/i.test(stem)
  ) {
    return null;
  }

  const fullDateTimeIso = cleanName.match(/(19\d{2}|20\d{2})[-_./](0[1-9]|1[0-2])[-_./](0[1-9]|[12]\d|3[01])[-_T\s]([01]\d|2[0-3])[:_.-]([0-5]\d)[:_.-]([0-5]\d)(?:[:_.-](\d{1,3}))?\s*(Z|[+-]\d{2}:?\d{2})?/i);
  if (fullDateTimeIso) {
    const [, y, m, d, hh, mm, ss, ms, tz] = fullDateTimeIso;
    let isoStr = `${y}-${m}-${d}T${hh}:${mm}:${ss}`;
    if (ms) isoStr += `.${ms.padStart(3, '0')}`;
    if (tz) isoStr += tz;
    else isoStr += 'Z';
    return parseDateString(isoStr);
  }

  const fullDateTimeCompact = cleanName.match(/(19\d{2}|20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])[-_T\s]?([01]\d|2[0-3])([0-5]\d)([0-5]\d)/);
  if (fullDateTimeCompact) {
    const [, y, m, d, hh, mm, ss] = fullDateTimeCompact;
    return parseDateString(`${y}-${m}-${d}T${hh}:${mm}:${ss}Z`);
  }

  const isoDate = cleanName.match(/(19\d{2}|20\d{2})[-_./](0[1-9]|1[0-2])[-_./](0[1-9]|[12]\d|3[01])/);
  if (isoDate) {
    return parseDateString(`${isoDate[1]}-${isoDate[2]}-${isoDate[3]}T12:00:00Z`);
  }

  const usDate = cleanName.match(/(0[1-9]|1[0-2])[-_./](0[1-9]|[12]\d|3[01])[-_./](19\d{2}|20\d{2})/);
  if (usDate) {
    return parseDateString(`${usDate[3]}-${usDate[1]}-${usDate[2]}T12:00:00Z`);
  }

  const compactDate = cleanName.match(/(19\d{2}|20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])/);
  if (compactDate) {
    return parseDateString(`${compactDate[1]}-${compactDate[2]}-${compactDate[3]}T12:00:00Z`);
  }

  // Do not match timestamp numbers if stem contains hex/alphanumeric mix (e.g. UUID fragments)
  if (/[a-zA-Z]/.test(stem)) return null;

  const millis = cleanName.match(/(?:^|[^0-9])([12]\d{12})(?:[^0-9]|$)/);
  if (millis) return parseDateString(Number(millis[1]));

  const seconds = cleanName.match(/(?:^|[^0-9])([12]\d{9})(?:[^0-9]|$)/);
  if (seconds) return parseDateString(Number(seconds[1]) * 1000);

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
            let str = '';
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
    return parseDateString(bestDateTimeString);
  }
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
      if (chunkType === 'EXIF' && payloadOffset < bytes.length) {
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

      if (chunkType === 'eXIf' && payloadOffset < bytes.length) {
        const res = parseTiffExifDate(bytes, payloadOffset);
        if (res) return res;
      } else if (chunkType === 'tIME' && payloadOffset + 7 <= bytes.length) {
        const year = (bytes[payloadOffset] << 8) | bytes[payloadOffset + 1];
        const month = bytes[payloadOffset + 2];
        const day = bytes[payloadOffset + 3];
        const hour = bytes[payloadOffset + 4];
        const minute = bytes[payloadOffset + 5];
        const second = bytes[payloadOffset + 6];
        const iso = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}T${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}:${String(second).padStart(2, '0')}Z`;
        const res = parseDateString(iso);
        if (res) return res;
      } else if ((chunkType === 'tEXt' || chunkType === 'iTXt') && payloadOffset + chunkSize <= bytes.length) {
        let keyword = '';
        let kOffset = payloadOffset;
        while (kOffset < payloadOffset + chunkSize && bytes[kOffset] !== 0) {
          keyword += String.fromCharCode(bytes[kOffset]);
          kOffset++;
        }
        const cleanKw = keyword.toLowerCase().trim();
        if (cleanKw.includes('creation') || cleanKw.includes('date') || cleanKw.includes('time')) {
          let textVal = '';
          for (let p = kOffset + 1; p < payloadOffset + chunkSize; p++) {
            if (bytes[p] === 0) continue;
            textVal += String.fromCharCode(bytes[p]);
          }
          const res = parseDateString(textVal);
          if (res) return res;
        }
      }
      offset += 12 + chunkSize;
    }
  }

  return null;
}

async function extractPhotoCapturedDate(file) {
  if (!file) return null;

  try {
    const slice = file.slice(0, 524288);
    const buf = await slice.arrayBuffer();
    const exifDate = parseExifDate(buf);
    if (exifDate) return exifDate;
  } catch (e) {
    // Ignore buffer read errors
  }

  const nameDate = dateFromFilename(file.name);
  if (nameDate) return nameDate;

  if (file.lastModified) {
    const lm = new Date(file.lastModified);
    if (!Number.isNaN(lm.getTime())) return lm.toISOString();
  }

  return null;
}

const Storage = {
  DB_NAME: 'PocketPicDB',
  DB_VERSION: 1,
  PHOTOS_STORE: 'photos',
  SETTINGS_STORE: 'settings',
  db: null,
  syncPromise: null,
  syncQueued: false,
  lastSyncedAt: null,
  syncState: 'idle',
  syncMessage: '',

  async init() {
    if (this.db) return this.db;

    return new Promise((resolve) => {
      const request = indexedDB.open(this.DB_NAME, this.DB_VERSION);

      request.onupgradeneeded = (event) => {
        const db = event.target.result;
        if (!db.objectStoreNames.contains(this.PHOTOS_STORE)) {
          const photoStore = db.createObjectStore(this.PHOTOS_STORE, { keyPath: 'id' });
          photoStore.createIndex('date', 'date', { unique: false });
        }
        if (!db.objectStoreNames.contains(this.SETTINGS_STORE)) {
          db.createObjectStore(this.SETTINGS_STORE, { keyPath: 'key' });
        }
      };

      request.onsuccess = (event) => {
        this.db = event.target.result;
        resolve(this.db);
      };

      request.onerror = (event) => {
        console.error('IndexedDB error:', event.target.error);
        resolve(null);
      };
    });
  },

  async getR2Url() {
    if (window.POCKETPIC_R2_URL) return window.POCKETPIC_R2_URL.trim().replace(/\/+$/, '');
    const customUrl = await this.getSetting('r2Url', null);
    return customUrl ? customUrl.trim().replace(/\/+$/, '') : 'https://c4082e46de92362b88f334060c85e78d.r2.cloudflarestorage.com/pocketpic';
  },

  setSyncState(state, message = '') {
    this.syncState = state;
    this.syncMessage = message;
    if (state === 'idle') this.lastSyncedAt = new Date();
    window.dispatchEvent(new CustomEvent('pocketpic:sync-status', { detail: { state, message } }));
  },

  notifyPhotosChanged() {
    window.dispatchEvent(new CustomEvent('pocketpic:photos-changed'));
  },

  async savePhoto(imageSource, metadata = {}) {
    await this.init();

    const maxDimension = await this.getSetting('maxDimension', 3840);
    const quality = await this.getSetting('compressionQuality', 0.85);
    const format = await this.getSetting('imageFormat', 'image/webp');
    const { blob, width, height, aspectRatio } = await this.compressImage(imageSource, maxDimension, quality, format);

    const id = metadata.id || crypto.randomUUID();
    let fallbackDate = new Date().toISOString();
    if (imageSource && typeof imageSource === 'object' && imageSource.lastModified) {
      const lmDate = new Date(imageSource.lastModified);
      if (!Number.isNaN(lmDate.getTime())) {
        fallbackDate = lmDate.toISOString();
      }
    }

    const record = {
      id,
      date: metadata.date || fallbackDate,
      blob,
      width,
      height,
      aspectRatio,
      filename: `${id}.${this.extensionFor(blob.type)}`,
      mimeType: blob.type,
      updatedAt: metadata.updatedAt || null,
      pending: true
    };

    await this.putRecord(record);
    this.notifyPhotosChanged();
    this.sync().catch(() => {});
    return record;
  },

  async updatePhotoDate(id, newDate) {
    const existing = await this.getPhoto(id);
    if (!existing) throw new Error('Photo not found');
    const parsed = new Date(newDate);
    if (Number.isNaN(parsed.getTime())) throw new Error('Invalid date');

    const updatedRecord = {
      ...existing,
      date: parsed.toISOString(),
      updatedAt: new Date().toISOString(),
      pending: true
    };
    await this.putRecord(updatedRecord);
    this.notifyPhotosChanged();
    this.sync().catch(() => {});
    return updatedRecord;
  },

  async importPhotos(fileList) {
    const files = Array.from(fileList || []);
    let importedCount = 0;

    for (const file of files) {
      if (!file.type.startsWith('image/')) continue;

      const dateISO = await extractPhotoCapturedDate(file);

      const canvas = await this.blobToCanvas(file);
      await this.savePhoto(canvas, { date: dateISO });
      importedCount++;
    }

    if (importedCount > 0) {
      this.notifyPhotosChanged();
    }
    return importedCount;
  },

  async replacePhoto(id, file) {
    const existing = await this.getPhoto(id);
    if (!existing) throw new Error('Photo not found');
    const canvas = await this.blobToCanvas(file);
    return this.savePhoto(canvas, { id, date: existing.date, updatedAt: existing.updatedAt });
  },

  async deletePhoto(id) {
    return this.deletePhotos([id]);
  },

  async deletePhotos(ids) {
    const validIds = Array.from(ids || []).filter(Boolean);
    for (const id of validIds) await this.deleteRecord(id);

    // Queue pending deletion IDs
    const pendingDeletes = new Set(await this.getSetting('pendingDeletes', []));
    for (const id of validIds) pendingDeletes.add(id);
    await this.setSetting('pendingDeletes', Array.from(pendingDeletes));

    this.notifyPhotosChanged();
    this.sync().catch(() => {});
    return true;
  },

  sync() {
    if (this.syncPromise) {
      this.syncQueued = true;
      return this.syncPromise;
    }
    this.syncPromise = this.runSync().finally(() => {
      this.syncPromise = null;
      if (this.syncQueued) {
        this.syncQueued = false;
        this.sync().catch(() => {});
      }
    });
    return this.syncPromise;
  },

  async runSync() {
    await this.init();
    this.setSyncState('syncing');
    let changed = false;

    try {
      // 1. Process pending remote deletions first
      const pendingDeletes = await this.getSetting('pendingDeletes', []);
      if (Array.isArray(pendingDeletes) && pendingDeletes.length > 0) {
        try {
          const res = await fetch('/api/photos/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ids: pendingDeletes }),
            credentials: 'same-origin'
          });
          if (res.status === 401) throw new LockedError();
          if (res.ok) {
            await this.setSetting('pendingDeletes', []);
          }
        } catch (e) {
          if (e instanceof LockedError) throw e;
          // Ignore network delete error and retry later
        }
      }

      // 2. Fetch remote list
      const remote = await this.fetchRemoteList();

      if (remote === null) {
        this.setSyncState('idle', 'Local storage mode');
        return false;
      }

      const allLocal = await this.getAllPhotos();
      const localById = new Map(allLocal.map((record) => [record.id, record]));

      // 3. Upload pending local records to remote Worker API
      for (const record of allLocal) {
        if (record.pending && record.blob) {
          const uploaded = await this.uploadPhotoToRemote(record);
          if (uploaded) {
            await this.putRecord({ ...record, pending: false, updatedAt: uploaded.updatedAt || record.updatedAt });
            changed = true;
          }
        }
      }

      // Re-read remote list if uploads occurred to sync updated state
      const updatedRemote = changed ? (await this.fetchRemoteList() || remote) : remote;

      const toDownload = [];
      for (const meta of updatedRemote) {
        const record = localById.get(meta.id);
        if (!record) {
          toDownload.push(meta);
        } else if (!record.blob) {
          toDownload.push(meta);
        } else {
          const localUpdated = record.updatedAt ? new Date(record.updatedAt).getTime() : 0;
          const remoteUpdated = meta.updatedAt ? new Date(meta.updatedAt).getTime() : 0;

          if (record.date !== meta.date) {
            if (localUpdated > remoteUpdated) {
              // Local date edit is newer; push to remote
              await this.uploadPhotoToRemote(record);
            } else {
              // Accept remote date edit
              await this.putRecord({
                ...record,
                date: meta.date,
                updatedAt: meta.updatedAt,
                pending: false
              });
              changed = true;
            }
          } else if (localUpdated < remoteUpdated) {
            toDownload.push(meta);
          }
        }
      }

      for (let i = 0; i < toDownload.length; i += 4) {
        await Promise.all(toDownload.slice(i, i + 4).map((meta) => this.downloadPhoto(meta)));
        changed = true;
      }

      this.setSyncState('idle');
    } catch (e) {
      if (e instanceof LockedError) {
        this.setSyncState('locked');
      } else {
        console.warn('Sync notice:', e);
        this.setSyncState('idle', 'Local storage mode');
      }
    }

    if (changed) this.notifyPhotosChanged();
    return changed;
  },

  async fetchRemoteList() {
    try {
      const res = await fetch('/api/photos', { cache: 'no-store', credentials: 'same-origin' });
      if (res.status === 401) throw new LockedError();
      if (res.ok) {
        const body = await res.json();
        const list = Array.isArray(body) ? body : (Array.isArray(body?.photos) ? body.photos : []);
        return list;
      }
    } catch (e) {
      if (e instanceof LockedError) throw e;
      // Worker API not reachable; fall back to direct R2 URL if configured
    }

    const r2Url = await this.getR2Url();
    if (!r2Url) return null;

    try {
      const res = await fetch(`${r2Url}/index/photos.json`, { cache: 'no-store' });
      if (res.ok) {
        const body = await res.json();
        const list = Array.isArray(body) ? body : (Array.isArray(body?.photos) ? body.photos : []);
        return list;
      }
    } catch (e) {
      console.warn('Direct R2 index fetch warning:', e);
    }
    return null;
  },

  async uploadPhotoToRemote(record) {
    if (!record || !record.blob) return null;
    try {
      const headers = {
        'Content-Type': record.mimeType || record.blob.type || 'image/jpeg',
        'X-Photo-Date': record.date
      };
      if (record.width) headers['X-Photo-Width'] = String(record.width);
      if (record.height) headers['X-Photo-Height'] = String(record.height);

      const res = await fetch(`/api/photos/${encodeURIComponent(record.id)}`, {
        method: 'PUT',
        headers,
        body: record.blob,
        credentials: 'same-origin'
      });
      if (res.status === 401) throw new LockedError();
      if (res.ok) {
        const data = await res.json();
        return data?.photo || { id: record.id, date: record.date };
      }
    } catch (e) {
      if (e instanceof LockedError) throw e;
      console.warn('Remote upload warning:', e);
    }
    return null;
  },

  async downloadPhoto(meta) {
    let blob = null;

    try {
      const res = await fetch(`/api/photos/${encodeURIComponent(meta.id)}`, { credentials: 'same-origin' });
      if (res.status === 401) throw new LockedError();
      if (res.ok) {
        blob = await res.blob();
      }
    } catch (e) {
      if (e instanceof LockedError) throw e;
      // Worker API fetch failed; fall back to direct R2 URL
    }

    if (!blob) {
      const r2Url = await this.getR2Url();
      if (r2Url && meta.key) {
        try {
          const res = await fetch(`${r2Url}/${meta.key}`);
          if (res.ok) blob = await res.blob();
        } catch (e) {
          console.warn('Direct R2 photo download warning:', e);
        }
      }
    }

    if (!blob) return;

    let { width, height } = meta;
    if (!width || !height) {
      const dims = await this.compressImage(blob);
      width = dims.width;
      height = dims.height;
    }
    await this.putRecord({
      id: meta.id,
      date: meta.date,
      blob,
      width,
      height,
      aspectRatio: width && height ? width / height : 1,
      filename: meta.key ? meta.key.split('/').pop() : `${meta.id}.jpg`,
      mimeType: meta.mimeType || blob.type,
      updatedAt: meta.updatedAt,
      pending: false
    });
  },

  async putRecord(record) {
    await this.init();
    if (!this.db) return false;
    return this.request(this.PHOTOS_STORE, 'readwrite', (store) => store.put(record), false);
  },

  async deleteRecord(id) {
    await this.init();
    if (!this.db) return false;
    return this.request(this.PHOTOS_STORE, 'readwrite', (store) => store.delete(id), false);
  },

  async getAllPhotos() {
    await this.init();
    if (!this.db) return [];
    const photos = await this.request(this.PHOTOS_STORE, 'readonly', (store) => store.getAll(), []);
    return (photos || []).sort((a, b) => new Date(b.date) - new Date(a.date));
  },

  async getPhoto(id) {
    await this.init();
    if (!this.db) return null;
    return this.request(this.PHOTOS_STORE, 'readonly', (store) => store.get(id), null);
  },

  request(storeName, mode, makeRequest, fallback) {
    return new Promise((resolve) => {
      try {
        const tx = this.db.transaction([storeName], mode);
        const request = makeRequest(tx.objectStore(storeName));
        request.onsuccess = () => resolve(mode === 'readwrite' ? true : request.result);
        request.onerror = () => resolve(fallback);
      } catch (e) {
        console.warn('IndexedDB request error:', e);
        resolve(fallback);
      }
    });
  },

  extensionFor(mimeType) {
    if (mimeType === 'image/webp') return 'webp';
    if (mimeType === 'image/png') return 'png';
    return 'jpg';
  },

  blobToCanvas(blob) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        URL.revokeObjectURL(img.src);
        const canvas = document.createElement('canvas');
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
        canvas.getContext('2d').drawImage(img, 0, 0);
        resolve(canvas);
      };
      img.onerror = () => {
        URL.revokeObjectURL(img.src);
        reject(new Error('Could not read that image'));
      };
      img.src = URL.createObjectURL(blob);
    });
  },

  encodeCanvas(canvas, preferredFormat, quality) {
    return new Promise((resolve, reject) => {
      canvas.toBlob((blob) => {
        if (blob && blob.type === preferredFormat) {
          resolve(blob);
          return;
        }
        canvas.toBlob((jpegBlob) => {
          if (jpegBlob) resolve(jpegBlob);
          else reject(new Error('Could not encode photo'));
        }, 'image/jpeg', quality);
      }, preferredFormat, quality);
    });
  },

  async compressImage(source, maxDimension = 3840, quality = 0.85, preferredFormat = 'image/webp') {
    if (source instanceof Blob) {
      return new Promise((resolve) => {
        const img = new Image();
        img.onload = () => {
          URL.revokeObjectURL(img.src);
          const width = img.naturalWidth || img.width;
          const height = img.naturalHeight || img.height;
          resolve({ blob: source, width, height, aspectRatio: width / height });
        };
        img.onerror = () => {
          URL.revokeObjectURL(img.src);
          resolve({ blob: source, width: null, height: null, aspectRatio: 1 });
        };
        img.src = URL.createObjectURL(source);
      });
    }

    if (!(source instanceof HTMLCanvasElement || source instanceof HTMLVideoElement)) {
      throw new Error('Unsupported image source type');
    }

    const sourceWidth = source.videoWidth || source.width;
    const sourceHeight = source.videoHeight || source.height;
    if (!sourceWidth || !sourceHeight) throw new Error('Camera is not ready yet');

    const scale = Math.min(1, maxDimension / Math.max(sourceWidth, sourceHeight));
    const width = Math.round(sourceWidth * scale);
    const height = Math.round(sourceHeight * scale);

    let canvas = source;
    if (!(source instanceof HTMLCanvasElement) || scale < 1) {
      canvas = document.createElement('canvas');
      canvas.width = width;
      canvas.height = height;
      canvas.getContext('2d').drawImage(source, 0, 0, width, height);
    }

    const blob = await this.encodeCanvas(canvas, preferredFormat, quality);
    return { blob, width, height, aspectRatio: width / height };
  },

  async getSetting(key, defaultValue = null) {
    await this.init();
    if (!this.db) return defaultValue;
    const result = await this.request(this.SETTINGS_STORE, 'readonly', (store) => store.get(key), null);
    return result ? result.value : defaultValue;
  },

  async setSetting(key, value) {
    await this.init();
    if (!this.db) return false;
    return this.request(this.SETTINGS_STORE, 'readwrite', (store) => store.put({ key, value }), false);
  }
};

window.Storage = Storage;
window.LockedError = LockedError;
