//
// Camera module for PocketPic Web
// Keeps the selected photo format, live preview, ghost overlay, and saved crop consistent across devices.
//

const Camera = {
  stream: null,
  videoElement: null,
  overlayCanvas: null,
  facingMode: 'user', // 'user' (front) or 'environment' (back)
  availableDevices: [],
  currentDeviceId: null,
  overlayOpacity: 0.4,
  overlayImage: null,
  overlayObjectUrl: null,
  isOverlayVisible: true,
  imageCapture: null,
  sessionVersion: 0,
  photoOrientation: 'landscape',
  mirrored: true,

  async init(videoEl, overlayCanvasEl) {
    this.videoElement = videoEl;
    this.overlayCanvas = overlayCanvasEl;
    try {
      if (window.Storage) {
        this.overlayOpacity = (await Storage.getSetting('overlayOpacity', 0.4));
        const orientation = await Storage.getSetting('photoOrientation', 'landscape');
        this.photoOrientation = orientation === 'portrait' ? 'portrait' : 'landscape';
      }
    } catch (e) {
      console.warn('Storage overlayOpacity setting load error:', e);
    }
    this.videoElement.addEventListener('resize', () => this.adjustViewfinderAspect());
    this.videoElement.addEventListener('loadedmetadata', () => this.adjustViewfinderAspect());
    this.adjustViewfinderAspect();
    await this.enumerateDevices();
  },

  async enumerateDevices() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
      console.warn('MediaDevices API not supported in this environment');
      this.availableDevices = [];
      return [];
    }

    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      this.availableDevices = devices.filter(d => d.kind === 'videoinput');
      return this.availableDevices;
    } catch (e) {
      console.warn('Error enumerating cameras:', e);
      this.availableDevices = [];
      return [];
    }
  },

  async startSession(facingMode = null, deviceId = null) {
    this.stopSession();
    const version = this.sessionVersion;
    if (!navigator.mediaDevices?.getUserMedia) return false;
    if (facingMode) this.facingMode = facingMode;
    if (deviceId) this.currentDeviceId = deviceId;

    const source = this.currentDeviceId
      ? { deviceId: { exact: this.currentDeviceId } }
      : { facingMode: { ideal: this.facingMode } };
    let stream;
    try {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          video: { ...source, width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false
        });
      } catch (error) {
        // Do not prompt again after a permission denial or start a different camera.
        if (!['OverconstrainedError', 'NotFoundError'].includes(error.name)) throw error;
        if (version !== this.sessionVersion) return false;
        stream = await navigator.mediaDevices.getUserMedia({ video: source, audio: false });
      }
      if (version !== this.sessionVersion) {
        stream.getTracks().forEach(track => track.stop());
        return false;
      }
      this.stream = stream;
      const track = stream.getVideoTracks()[0];
      const settings = track?.getSettings?.() || {};
      this.currentDeviceId = settings.deviceId || this.currentDeviceId;
      this.mirrored = settings.facingMode ? settings.facingMode === 'user' : this.facingMode === 'user';
      this.videoElement.style.transform = this.mirrored ? 'scaleX(-1)' : 'none';
      this.videoElement.srcObject = stream;
      await this.videoElement.play();
      if (version !== this.sessionVersion) return false;
      this.adjustViewfinderAspect();
      await this.enumerateDevices();
      await this.updateGhostOverlay();
      return version === this.sessionVersion;
    } catch (error) {
      stream?.getTracks().forEach(track => track.stop());
      if (version === this.sessionVersion) this.stopSession();
      console.warn('Camera unavailable:', error);
      return false;
    }
  },

  get captureRatio() {
    return this.photoOrientation === 'portrait' ? 3 / 4 : 4 / 3;
  },

  async togglePhotoOrientation() {
    this.photoOrientation = this.photoOrientation === 'landscape' ? 'portrait' : 'landscape';
    this.adjustViewfinderAspect();
    await Storage.setSetting('photoOrientation', this.photoOrientation);
  },

  adjustViewfinderAspect() {
    if (!this.videoElement) return;
    this.videoElement.closest('.viewfinder-wrapper')?.style.setProperty('--vf-ratio', String(this.captureRatio));
    const button = document.getElementById('camera-orientation-btn');
    if (button) {
      button.textContent = this.photoOrientation === 'landscape' ? '▭ Landscape' : '▯ Portrait';
      button.setAttribute('aria-label', `Photo format: ${this.photoOrientation}. Switch to ${this.photoOrientation === 'landscape' ? 'portrait' : 'landscape'}`);
    }
    this.updateResolutionBadge();
    this.renderOverlay();
  },

  cropRect() {
    const width = this.videoElement?.videoWidth || 0;
    const height = this.videoElement?.videoHeight || 0;
    if (!width || !height) return null;
    const cropWidth = Math.min(width, height * this.captureRatio);
    const cropHeight = cropWidth / this.captureRatio;
    return {
      x: (width - cropWidth) / 2, y: (height - cropHeight) / 2,
      width: cropWidth, height: cropHeight,
      outputWidth: Math.round(cropWidth), outputHeight: Math.round(cropHeight)
    };
  },

  updateResolutionBadge() {
    const badge = document.getElementById('camera-resolution-badge');
    if (badge && this.videoElement) {
      const crop = this.cropRect();
      const w = crop?.outputWidth || 0;
      const h = crop?.outputHeight || 0;
      if (w && h) {
        badge.textContent = `${w} × ${h}`;
        badge.style.display = 'inline-block';
      } else {
        badge.style.display = 'none';
      }
    }
  },

  stopSession() {
    this.sessionVersion++;
    if (this.stream) {
      this.stream.getTracks().forEach(track => track.stop());
      this.stream = null;
    }
    if (this.videoElement) {
      this.videoElement.srcObject = null;
    }
    this.imageCapture = null;
  },

  async switchCamera() {
    // Phones may expose several lenses for the same facing direction.
    if (window.matchMedia('(pointer: coarse)').matches || this.availableDevices.length < 2) {
      this.facingMode = this.facingMode === 'user' ? 'environment' : 'user';
      this.currentDeviceId = null;
    } else {
      const index = this.availableDevices.findIndex(device => device.deviceId === this.currentDeviceId);
      this.currentDeviceId = this.availableDevices[(index + 1) % this.availableDevices.length].deviceId;
    }
    return this.startSession();
  },

  async setOverlayPhoto(blobOrUrl) {
    if (!blobOrUrl) {
      this.overlayImage = null;
      if (this.overlayObjectUrl) URL.revokeObjectURL(this.overlayObjectUrl);
      this.overlayObjectUrl = null;
      this.clearOverlay();
      return;
    }

    return new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        this.overlayImage = img;
        this.renderOverlay();
        resolve(true);
      };
      img.onerror = () => {
        this.overlayImage = null;
        this.clearOverlay();
        resolve(false);
      };

      if (blobOrUrl instanceof Blob) {
        if (this.overlayObjectUrl) URL.revokeObjectURL(this.overlayObjectUrl);
        this.overlayObjectUrl = URL.createObjectURL(blobOrUrl);
        img.src = this.overlayObjectUrl;
      } else {
        img.src = blobOrUrl;
      }
    });
  },

  async updateGhostOverlay() {
    if (!window.Storage) return;
    try {
      const photos = await Storage.getAllPhotos();
      if (photos.length > 0) {
        const lastPhoto = photos[0];
        await this.setOverlayPhoto(lastPhoto.blob);
      } else {
        await this.setOverlayPhoto(null);
      }
    } catch (e) {
      console.warn('Error loading photos for ghost overlay:', e);
    }
  },

  setOverlayOpacity(opacity) {
    this.overlayOpacity = opacity;
    if (window.Storage) {
      Storage.setSetting('overlayOpacity', opacity);
    }
    this.renderOverlay();
  },

  toggleOverlay(visible = null) {
    this.isOverlayVisible = visible !== null ? visible : !this.isOverlayVisible;
    this.renderOverlay();
    return this.isOverlayVisible;
  },

  renderOverlay() {
    if (!this.overlayCanvas || !this.videoElement) return;

    const canvas = this.overlayCanvas;
    const ctx = canvas.getContext('2d');

    const crop = this.cropRect();
    const videoW = crop?.outputWidth || 800;
    const videoH = crop?.outputHeight || Math.round(800 / this.captureRatio);

    if (canvas.width !== videoW) canvas.width = videoW;
    if (canvas.height !== videoH) canvas.height = videoH;

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (this.isOverlayVisible && this.overlayImage) {
      ctx.globalAlpha = this.overlayOpacity;

      const imgW = this.overlayImage.width;
      const imgH = this.overlayImage.height;

      const scale = Math.max(videoW / imgW, videoH / imgH);
      const drawW = imgW * scale;
      const drawH = imgH * scale;
      const x = (videoW - drawW) / 2;
      const y = (videoH - drawH) / 2;

      ctx.drawImage(this.overlayImage, x, y, drawW, drawH);
      ctx.globalAlpha = 1.0;
    }
  },

  clearOverlay() {
    if (!this.overlayCanvas) return;
    const ctx = this.overlayCanvas.getContext('2d');
    ctx.clearRect(0, 0, this.overlayCanvas.width, this.overlayCanvas.height);
  },

  async captureFrameBlob() {
    // Use the same crop and mirroring as the preview in every browser.
    const canvas = this.captureFrame();
    if (!canvas) return null;

    return new Promise((resolve) => {
      canvas.toBlob((blob) => resolve(blob), 'image/jpeg', 0.98);
    });
  },

  captureFrame() {
    if (!this.videoElement || !this.stream || !this.videoElement.videoWidth) return null;

    const video = this.videoElement;
    const canvas = document.createElement('canvas');

    const crop = this.cropRect();
    if (!crop) return null;
    canvas.width = crop.outputWidth;
    canvas.height = crop.outputHeight;
    const ctx = canvas.getContext('2d');
    if (this.mirrored) {
      ctx.translate(canvas.width, 0);
      ctx.scale(-1, 1);
    }
    ctx.drawImage(video, crop.x, crop.y, crop.width, crop.height, 0, 0, canvas.width, canvas.height);
    return canvas;
  }
};

window.Camera = Camera;
