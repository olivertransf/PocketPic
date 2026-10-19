//
// Storage module for PocketPic Web
// Manages local photo storage using IndexedDB, image compression, settings, and optional Cloudflare R2 backup.
//

const Storage = {
  DB_NAME: 'PocketPicDB',
  DB_VERSION: 1,
  PHOTOS_STORE: 'photos',
  SETTINGS_STORE: 'settings',
  db: null,

  async init() {
    if (this.db) return this.db;

    return new Promise((resolve, reject) => {
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
        reject(event.target.error);
      };
    });
  },

  // Save a photo (compresses image to WebP or JPEG blob first)
  async savePhoto(imageSource, metadata = {}) {
    await this.init();

    // Compression parameters from settings or default
    const maxDimension = await this.getSetting('maxDimension', 1920);
    const quality = await this.getSetting('compressionQuality', 0.85);
    const format = await this.getSetting('imageFormat', 'image/webp');

    // Compress image to blob
    const { blob, width, height, aspectRatio } = await this.compressImage(imageSource, maxDimension, quality, format);

    const id = metadata.id || crypto.randomUUID();
    const date = metadata.date || new Date().toISOString();

    const photoRecord = {
      id,
      date,
      blob,
      width,
      height,
      aspectRatio,
      filename: `${id}.${format === 'image/webp' ? 'webp' : 'jpg'}`,
      mimeType: blob.type
    };

    return new Promise((resolve, reject) => {
      const tx = this.db.transaction([this.PHOTOS_STORE], 'readwrite');
      const store = tx.objectStore(this.PHOTOS_STORE);
      const request = store.put(photoRecord);

      request.onsuccess = async () => {
        // Optional Cloudflare R2 backup sync
        this.syncToR2IfConfigured(photoRecord).catch(err => console.warn('R2 sync skipped or failed:', err));
        resolve(photoRecord);
      };

      request.onerror = (e) => reject(e.target.error);
    });
  },

  async getAllPhotos() {
    await this.init();
    return new Promise((resolve, reject) => {
      const tx = this.db.transaction([this.PHOTOS_STORE], 'readonly');
      const store = tx.objectStore(this.PHOTOS_STORE);
      const request = store.getAll();

      request.onsuccess = () => {
        const photos = request.result || [];
        // Sort newest first by default
        photos.sort((a, b) => new Date(b.date) - new Date(a.date));
        resolve(photos);
      };

      request.onerror = (e) => reject(e.target.error);
    });
  },

  async getPhoto(id) {
    await this.init();
    return new Promise((resolve, reject) => {
      const tx = this.db.transaction([this.PHOTOS_STORE], 'readonly');
      const store = tx.objectStore(this.PHOTOS_STORE);
      const request = store.get(id);

      request.onsuccess = () => resolve(request.result);
      request.onerror = (e) => reject(e.target.error);
    });
  },

  async deletePhoto(id) {
    await this.init();
    return new Promise((resolve, reject) => {
      const tx = this.db.transaction([this.PHOTOS_STORE], 'readwrite');
      const store = tx.objectStore(this.PHOTOS_STORE);
      const request = store.delete(id);

      request.onsuccess = () => resolve(true);
      request.onerror = (e) => reject(e.target.error);
    });
  },

  async deletePhotos(ids) {
    for (const id of ids) {
      await this.deletePhoto(id);
    }
    return true;
  },

  // Helper function to compress images using Canvas API
  async compressImage(source, maxDimension = 1920, quality = 0.85, preferredFormat = 'image/webp') {
    return new Promise((resolve, reject) => {
      const img = new Image();

      const process = () => {
        let width = img.naturalWidth || img.width;
        let height = img.naturalHeight || img.height;
        const aspectRatio = width / height;

        if (width > maxDimension || height > maxDimension) {
          if (width > height) {
            height = Math.round((maxDimension * height) / width);
            width = maxDimension;
          } else {
            width = Math.round((maxDimension * width) / height);
            height = maxDimension;
          }
        }

        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, width, height);

        // Fallback to jpeg if browser doesn't support webp canvas export
        let mime = preferredFormat;
        canvas.toBlob(
          (blob) => {
            if (!blob) {
              // Retry with image/jpeg
              canvas.toBlob(
                (jpegBlob) => {
                  resolve({ blob: jpegBlob, width, height, aspectRatio });
                },
                'image/jpeg',
                quality
              );
            } else {
              resolve({ blob, width, height, aspectRatio });
            }
          },
          mime,
          quality
        );
      };

      if (source instanceof Blob || source instanceof File) {
        img.src = URL.createObjectURL(source);
        img.onload = () => {
          URL.revokeObjectURL(img.src);
          process();
        };
        img.onerror = reject;
      } else if (typeof source === 'string') {
        img.src = source;
        img.onload = process;
        img.onerror = reject;
      } else if (source instanceof HTMLVideoElement || source instanceof HTMLCanvasElement) {
        let width = source.videoWidth || source.width;
        let height = source.videoHeight || source.height;
        const aspectRatio = width / height;

        if (width > maxDimension || height > maxDimension) {
          if (width > height) {
            height = Math.round((maxDimension * height) / width);
            width = maxDimension;
          } else {
            width = Math.round((maxDimension * width) / height);
            height = maxDimension;
          }
        }

        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(source, 0, 0, width, height);

        canvas.toBlob(
          (blob) => {
            resolve({ blob, width, height, aspectRatio });
          },
          preferredFormat,
          quality
        );
      } else {
        reject(new Error('Unsupported image source type'));
      }
    });
  },

  // Settings Storage Methods
  async getSetting(key, defaultValue = null) {
    await this.init();
    return new Promise((resolve) => {
      const tx = this.db.transaction([this.SETTINGS_STORE], 'readonly');
      const store = tx.objectStore(this.SETTINGS_STORE);
      const request = store.get(key);

      request.onsuccess = () => {
        resolve(request.result ? request.result.value : defaultValue);
      };
      request.onerror = () => resolve(defaultValue);
    });
  },

  async setSetting(key, value) {
    await this.init();
    return new Promise((resolve, reject) => {
      const tx = this.db.transaction([this.SETTINGS_STORE], 'readwrite');
      const store = tx.objectStore(this.SETTINGS_STORE);
      const request = store.put({ key, value });

      request.onsuccess = () => resolve(true);
      request.onerror = (e) => reject(e.target.error);
    });
  },

  // Cloudflare R2 Upload Helper (Optional S3 / Pre-Signed URL upload)
  async syncToR2IfConfigured(photoRecord) {
    const r2Endpoint = await this.getSetting('r2Endpoint');
    const r2AccessKey = await this.getSetting('r2AccessKey');
    const r2SecretKey = await this.getSetting('r2SecretKey');
    const r2Bucket = await this.getSetting('r2Bucket', 'pocket-pic');

    if (!r2Endpoint || !r2AccessKey || !r2SecretKey) {
      return false; // R2 direct API creds not configured
    }

    // Direct HTTP upload if worker or pre-signed URL proxy endpoint is set
    try {
      const uploadUrl = `${r2Endpoint.replace(/\/$/, '')}/${r2Bucket}/${photoRecord.filename}`;
      const response = await fetch(uploadUrl, {
        method: 'PUT',
        headers: {
          'Content-Type': photoRecord.mimeType
        },
        body: photoRecord.blob
      });
      return response.ok;
    } catch (e) {
      console.warn('R2 sync error:', e);
      return false;
    }
  }
};

window.Storage = Storage;
