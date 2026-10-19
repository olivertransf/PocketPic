//
// Storage module for PocketPic Web
// Manages local photo storage using IndexedDB, high resolution image compression, settings, and Cloudflare R2 S3/SigV4 sync.
//

const Storage = {
  DB_NAME: 'PocketPicDB',
  DB_VERSION: 1,
  PHOTOS_STORE: 'photos',
  SETTINGS_STORE: 'settings',
  db: null,

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

  // Save a photo (compresses image matching macOS high resolution sensor output)
  async savePhoto(imageSource, metadata = {}) {
    await this.init();

    const maxDimension = await this.getSetting('maxDimension', 3840);
    const quality = await this.getSetting('compressionQuality', 0.85);
    const format = await this.getSetting('imageFormat', 'image/webp');

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
      filename: metadata.filename || `${id}.${format === 'image/webp' ? 'webp' : 'jpg'}`,
      mimeType: blob.type
    };

    if (!this.db) return photoRecord;

    return new Promise((resolve) => {
      try {
        const tx = this.db.transaction([this.PHOTOS_STORE], 'readwrite');
        const store = tx.objectStore(this.PHOTOS_STORE);
        const request = store.put(photoRecord);

        request.onsuccess = async () => {
          this.syncToR2IfConfigured(photoRecord).catch(err => console.warn('R2 sync skipped/failed:', err));
          resolve(photoRecord);
        };

        request.onerror = () => resolve(photoRecord);
      } catch (e) {
        console.warn('savePhoto transaction error:', e);
        resolve(photoRecord);
      }
    });
  },

  async getAllPhotos() {
    await this.init();
    if (!this.db) return [];

    return new Promise((resolve) => {
      try {
        const tx = this.db.transaction([this.PHOTOS_STORE], 'readonly');
        const store = tx.objectStore(this.PHOTOS_STORE);
        const request = store.getAll();

        request.onsuccess = () => {
          const photos = request.result || [];
          photos.sort((a, b) => new Date(b.date) - new Date(a.date));
          resolve(photos);
        };

        request.onerror = () => resolve([]);
      } catch (e) {
        console.warn('getAllPhotos transaction error:', e);
        resolve([]);
      }
    });
  },

  async getPhoto(id) {
    await this.init();
    if (!this.db) return null;

    return new Promise((resolve) => {
      try {
        const tx = this.db.transaction([this.PHOTOS_STORE], 'readonly');
        const store = tx.objectStore(this.PHOTOS_STORE);
        const request = store.get(id);

        request.onsuccess = () => resolve(request.result);
        request.onerror = () => resolve(null);
      } catch (e) {
        resolve(null);
      }
    });
  },

  async deletePhoto(id) {
    await this.init();
    if (!this.db) return true;

    return new Promise((resolve) => {
      try {
        const tx = this.db.transaction([this.PHOTOS_STORE], 'readwrite');
        const store = tx.objectStore(this.PHOTOS_STORE);
        const request = store.delete(id);

        request.onsuccess = () => resolve(true);
        request.onerror = () => resolve(false);
      } catch (e) {
        resolve(false);
      }
    });
  },

  async deletePhotos(ids) {
    for (const id of ids) {
      await this.deletePhoto(id);
    }
    return true;
  },

  // Compress image helper using Canvas API
  async compressImage(source, maxDimension = 3840, quality = 0.95, preferredFormat = 'image/webp') {
    return new Promise((resolve, reject) => {
      if (source instanceof Blob && source.type.includes('image/')) {
        // Source is already a processed image blob
        const img = new Image();
        img.onload = () => {
          URL.revokeObjectURL(img.src);
          const width = img.naturalWidth || img.width;
          const height = img.naturalHeight || img.height;
          resolve({ blob: source, width, height, aspectRatio: width / height });
        };
        img.onerror = () => resolve({ blob: source, width: 1920, height: 1080, aspectRatio: 16/9 });
        img.src = URL.createObjectURL(source);
        return;
      }

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

        canvas.toBlob(
          (blob) => {
            if (!blob) {
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
          preferredFormat,
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
        let width = source.videoWidth || source.width || 3840;
        let height = source.videoHeight || source.height || 2160;
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

  // Settings Storage Methods with safe fallbacks
  async getSetting(key, defaultValue = null) {
    await this.init();
    if (!this.db) return defaultValue;

    return new Promise((resolve) => {
      try {
        const tx = this.db.transaction([this.SETTINGS_STORE], 'readonly');
        const store = tx.objectStore(this.SETTINGS_STORE);
        const request = store.get(key);

        request.onsuccess = () => {
          resolve(request.result ? request.result.value : defaultValue);
        };
        request.onerror = () => resolve(defaultValue);
      } catch (e) {
        resolve(defaultValue);
      }
    });
  },

  async setSetting(key, value) {
    await this.init();
    if (!this.db) return false;

    return new Promise((resolve) => {
      try {
        const tx = this.db.transaction([this.SETTINGS_STORE], 'readwrite');
        const store = tx.objectStore(this.SETTINGS_STORE);
        const request = store.put({ key, value });

        request.onsuccess = () => resolve(true);
        request.onerror = () => resolve(false);
      } catch (e) {
        resolve(false);
      }
    });
  },

  // S3 / SigV4 HMAC Helper Methods for Cloudflare R2
  async sha256Hex(strOrBuffer) {
    const buffer = typeof strOrBuffer === 'string' ? new TextEncoder().encode(strOrBuffer) : strOrBuffer;
    const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
    return Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');
  },

  async hmacSha256(key, data) {
    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      typeof key === 'string' ? new TextEncoder().encode(key) : key,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    return await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(data));
  },

  async getSigV4Headers(method, urlStr, payloadBuffer = new Uint8Array(0)) {
    const accessKey = await this.getSetting('r2AccessKey');
    const secretKey = await this.getSetting('r2SecretKey');

    if (!accessKey || !secretKey) return null;

    const url = new URL(urlStr);
    const region = 'auto';
    const service = 's3';

    const now = new Date();
    const amzDate = now.toISOString().replace(/[:-]/g, '').split('.')[0] + 'Z';
    const dateStamp = amzDate.slice(0, 8);

    const payloadHash = await this.sha256Hex(payloadBuffer);

    const host = url.host;
    const canonicalHeaders = `host:${host}\nx-amz-content-sha256:${payloadHash}\nx-amz-date:${amzDate}\n`;
    const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';

    // Canonical Query String
    const searchParams = new URLSearchParams(url.search);
    const sortedKeys = Array.from(searchParams.keys()).sort();
    const canonicalQuery = sortedKeys
      .map(k => `${encodeURIComponent(k)}=${encodeURIComponent(searchParams.get(k))}`)
      .join('&');

    const canonicalRequest = [
      method,
      url.pathname,
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash
    ].join('\n');

    const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
    const stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      await this.sha256Hex(canonicalRequest)
    ].join('\n');

    // Calculate Signature
    const kDate = await this.hmacSha256(`AWS4${secretKey}`, dateStamp);
    const kRegion = await this.hmacSha256(kDate, region);
    const kService = await this.hmacSha256(kRegion, service);
    const kSigning = await this.hmacSha256(kService, 'aws4_request');
    const signatureBuffer = await this.hmacSha256(kSigning, stringToSign);
    const signature = Array.from(new Uint8Array(signatureBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');

    const authorization = `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

    return {
      'Authorization': authorization,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash
    };
  },

  // Upload photo record to Cloudflare R2
  async syncToR2IfConfigured(photoRecord) {
    const r2Endpoint = await this.getSetting('r2Endpoint', 'https://c4082e46de92362b88f334060c85e78d.r2.cloudflarestorage.com');
    const r2Bucket = await this.getSetting('r2Bucket', 'pocketpic');

    const uploadUrl = `${r2Endpoint.replace(/\/$/, '')}/${r2Bucket}/${photoRecord.filename}`;
    const arrayBuffer = await photoRecord.blob.arrayBuffer();

    const headers = await this.getSigV4Headers('PUT', uploadUrl, new Uint8Array(arrayBuffer));
    if (!headers) return false;

    try {
      const response = await fetch(uploadUrl, {
        method: 'PUT',
        headers: {
          ...headers,
          'Content-Type': photoRecord.mimeType
        },
        body: photoRecord.blob
      });
      return response.ok;
    } catch (e) {
      console.warn('R2 upload sync error:', e);
      return false;
    }
  },

  // Fetch photos directly from Cloudflare R2 bucket and load into local storage
  async syncFromR2() {
    const r2Endpoint = await this.getSetting('r2Endpoint', 'https://c4082e46de92362b88f334060c85e78d.r2.cloudflarestorage.com');
    const r2Bucket = await this.getSetting('r2Bucket', 'pocketpic');

    const listUrl = `${r2Endpoint.replace(/\/$/, '')}/${r2Bucket}?list-type=2`;
    const headers = await this.getSigV4Headers('GET', listUrl);

    if (!headers) {
      console.warn('R2 credentials not configured for bucket sync.');
      return false;
    }

    try {
      const response = await fetch(listUrl, { method: 'GET', headers });
      if (!response.ok) {
        console.warn('R2 ListObjects response not OK:', response.status);
        return false;
      }

      const xmlText = await response.text();
      const parser = new DOMParser();
      const xmlDoc = parser.parseFromString(xmlText, 'text/xml');
      const keyNodes = xmlDoc.getElementsByTagName('Key');

      let fetchedCount = 0;
      for (let i = 0; i < keyNodes.length; i++) {
        const key = keyNodes[i].textContent;
        if (!key || key.endsWith('/')) continue;

        const keyPath = key.split('/').map(segment => encodeURIComponent(segment)).join('/');
        const objectUrl = `${r2Endpoint.replace(/\/$/, '')}/${r2Bucket}/${keyPath}`;
        const objHeaders = await this.getSigV4Headers('GET', objectUrl);

        if (objHeaders) {
          const objResp = await fetch(objectUrl, { method: 'GET', headers: objHeaders });
          if (objResp.ok) {
            const blob = await objResp.blob();
            const lastModified = objResp.headers.get('Last-Modified') ? new Date(objResp.headers.get('Last-Modified')).toISOString() : new Date().toISOString();
            await this.savePhoto(blob, {
              id: key.split('.')[0] || crypto.randomUUID(),
              filename: key,
              date: lastModified
            });
            fetchedCount++;
          }
        }
      }
      return fetchedCount;
    } catch (e) {
      console.error('R2 syncFromR2 error:', e);
      return false;
    }
  }
};

window.Storage = Storage;
