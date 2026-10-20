//
// Storage module for PocketPic Web
// IndexedDB is a per-device cache. The R2 bucket, reached through the Worker at /api, is the shared copy.
//

const PHOTO_ID_PATTERN = /^[A-Za-z0-9_-]{1,100}$/;

class LockedError extends Error {
  constructor() {
    super('Locked');
    this.name = 'LockedError';
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

  async api(path, options = {}) {
    const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...options });
    if (response.status === 401) {
      window.dispatchEvent(new CustomEvent('pocketpic:locked'));
      throw new LockedError();
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
    const remoteIds = records.filter((r) => r && r.updatedAt).map((r) => r.id);
    if (remoteIds.length > 0) {
      await this.api('/api/photos/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: remoteIds })
      });
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
      } else {
        console.warn('Sync failed:', e);
        this.setSyncState('error', navigator.onLine === false ? 'Offline. Photos will upload when you reconnect.' : e.message);
      }
    }

    if (changed) this.notifyPhotosChanged();
    return changed;
  },

  async fetchRemoteList() {
    const response = await this.api('/api/photos');
    const body = await response.json();
    return Array.isArray(body.photos) ? body.photos : [];
  },

  async uploadRecord(record) {
    let id = record.id;
    if (!PHOTO_ID_PATTERN.test(id)) {
      await this.deleteRecord(id);
      id = crypto.randomUUID();
    }

    const headers = {
      'Content-Type': record.blob.type || record.mimeType || 'image/jpeg',
      'X-Photo-Date': record.date
    };
    if (record.width) headers['X-Photo-Width'] = String(record.width);
    if (record.height) headers['X-Photo-Height'] = String(record.height);

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
  },

  async downloadPhoto(meta) {
    const response = await this.api(`/api/photos/${encodeURIComponent(meta.id)}`);
    const blob = await response.blob();
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
      filename: meta.key.split('/').pop(),
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
