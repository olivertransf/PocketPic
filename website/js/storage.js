//
// Storage module for PocketPic Web
// IndexedDB is the primary per-device storage.
// Cloudflare R2 (via public bucket URL or Worker /api) provides shared remote sync when available.
//

const PHOTO_ID_PATTERN = /^[A-Za-z0-9_-]{1,100}$/;

class LockedError extends Error {
  constructor() {
    super('Locked');
    this.name = 'LockedError';
  }
}

class ServerNotFoundError extends Error {
  constructor() {
    super('Server API endpoint not found');
    this.name = 'ServerNotFoundError';
  }
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
    return customUrl ? customUrl.trim().replace(/\/+$/, '') : '';
  },

  async api(path, options = {}) {
    const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...options });
    if (response.status === 401) {
      window.dispatchEvent(new CustomEvent('pocketpic:locked'));
      throw new LockedError();
    }
    if (response.status === 404) {
      throw new ServerNotFoundError();
    }
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      throw new Error(body.error || `Server returned ${response.status}`);
    }
    return response;
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
    const record = {
      id,
      date: metadata.date || new Date().toISOString(),
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
    const records = await Promise.all(ids.map((id) => this.getPhoto(id)));
    const remoteRecords = records.filter((r) => r && r.updatedAt);
    const remoteIds = remoteRecords.map((r) => r.id);

    if (remoteIds.length > 0) {
      try {
        await this.api('/api/photos/delete', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ids: remoteIds })
        });
      } catch (e) {
        if (!(e instanceof ServerNotFoundError)) {
          console.warn('Remote delete warning:', e);
        }
      }
    }
    for (const id of ids) await this.deleteRecord(id);
    this.notifyPhotosChanged();
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
      const remote = await this.fetchRemoteList();

      if (remote === null) {
        this.setSyncState('idle', 'Local storage (no external server required)');
        return false;
      }

      const remoteById = new Map(remote.map((photo) => [photo.id, photo]));
      const local = await this.getAllPhotos();

      for (const record of local) {
        const neverSynced = !record.updatedAt && !remoteById.has(record.id);
        if (record.pending || neverSynced) {
          const uploaded = await this.uploadRecord(record);
          remoteById.set(uploaded.id, uploaded);
          changed = true;
        }
      }

      const localById = new Map((await this.getAllPhotos()).map((record) => [record.id, record]));
      const toDownload = [...remoteById.values()].filter((meta) => {
        const record = localById.get(meta.id);
        return !record || (!record.pending && record.updatedAt !== meta.updatedAt);
      });

      for (let i = 0; i < toDownload.length; i += 4) {
        await Promise.all(toDownload.slice(i, i + 4).map((meta) => this.downloadPhoto(meta)));
        changed = true;
      }

      for (const record of localById.values()) {
        if (!record.pending && !remoteById.has(record.id)) {
          await this.deleteRecord(record.id);
          changed = true;
        }
      }

      this.setSyncState('idle');
    } catch (e) {
      if (e instanceof LockedError) {
        this.setSyncState('locked');
      } else if (e instanceof ServerNotFoundError) {
        this.setSyncState('idle', 'Local storage (no external server required)');
      } else {
        console.warn('Sync failed:', e);
        this.setSyncState('error', navigator.onLine === false ? 'Offline. Photos will upload when you reconnect.' : e.message);
      }
    }

    if (changed) this.notifyPhotosChanged();
    return changed;
  },

  async fetchRemoteList() {
    const r2Url = await this.getR2Url();
    if (r2Url) {
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
    }

    try {
      const response = await this.api('/api/photos');
      const body = await response.json();
      return Array.isArray(body.photos) ? body.photos : [];
    } catch (e) {
      if (e instanceof ServerNotFoundError) {
        return null;
      }
      throw e;
    }
  },

  async uploadRecord(record) {
    let id = record.id;
    if (!PHOTO_ID_PATTERN.test(id)) {
      await this.deleteRecord(id);
      id = crypto.randomUUID();
    }

    const ext = this.extensionFor(record.blob.type || record.mimeType);
    const key = `photos/${id}.${ext}`;
    const contentType = record.blob.type || record.mimeType || 'image/jpeg';

    const headers = {
      'Content-Type': contentType,
      'X-Photo-Date': record.date
    };
    if (record.width) headers['X-Photo-Width'] = String(record.width);
    if (record.height) headers['X-Photo-Height'] = String(record.height);

    try {
      const response = await this.api(`/api/photos/${encodeURIComponent(id)}`, {
        method: 'PUT',
        headers,
        body: record.blob
      });
      const { photo } = await response.json();
      await this.putRecord({
        ...record,
        id: photo.id,
        date: photo.date,
        updatedAt: photo.updatedAt,
        filename: photo.key.split('/').pop(),
        pending: false
      });
      return photo;
    } catch (e) {
      if (e instanceof ServerNotFoundError) {
        await this.putRecord({
          ...record,
          id,
          pending: false
        });
        return {
          id,
          key,
          date: record.date,
          mimeType: contentType,
          width: record.width || null,
          height: record.height || null,
          size: record.blob.size,
          updatedAt: record.updatedAt || new Date().toISOString()
        };
      }
      throw e;
    }
  },

  async downloadPhoto(meta) {
    let blob = null;
    const r2Url = await this.getR2Url();

    if (r2Url && meta.key) {
      try {
        const res = await fetch(`${r2Url}/${meta.key}`);
        if (res.ok) blob = await res.blob();
      } catch (e) {
        console.warn('Direct R2 photo download warning:', e);
      }
    }

    if (!blob) {
      try {
        const response = await this.api(`/api/photos/${encodeURIComponent(meta.id)}`);
        blob = await response.blob();
      } catch (e) {
        if (e instanceof ServerNotFoundError) return;
        throw e;
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

  // Safari cannot encode WebP and silently returns PNG, so anything other than the requested type falls back to JPEG.
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
window.ServerNotFoundError = ServerNotFoundError;
