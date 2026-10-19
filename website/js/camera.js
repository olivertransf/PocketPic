//
// Camera module for PocketPic Web
// Manages video stream, camera switching, live viewfinder, ghost alignment overlay, and snapping photos.
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
  isOverlayVisible: true,

  async init(videoEl, overlayCanvasEl) {
    this.videoElement = videoEl;
    this.overlayCanvas = overlayCanvasEl;
    try {
      if (window.Storage) {
        this.overlayOpacity = (await Storage.getSetting('overlayOpacity', 0.4));
      }
    } catch (e) {
      console.warn('Storage overlayOpacity setting load error:', e);
    }
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
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      console.warn('getUserMedia API not supported in this environment');
      return false;
    }

    if (facingMode) this.facingMode = facingMode;
    if (deviceId) this.currentDeviceId = deviceId;

    this.stopSession();

    const constraints = {
      video: {
        width: { ideal: 1920 },
        height: { ideal: 1080 }
      }
    };

    if (this.currentDeviceId) {
      constraints.video.deviceId = { exact: this.currentDeviceId };
    } else if (this.facingMode) {
      constraints.video.facingMode = this.facingMode;
    }

    try {
      this.stream = await navigator.mediaDevices.getUserMedia(constraints);
      if (this.videoElement) {
        this.videoElement.srcObject = this.stream;
        await this.videoElement.play();
        this.videoElement.style.transform = (this.facingMode === 'user' && !this.currentDeviceId) ? 'scaleX(-1)' : 'none';
      }
      await this.enumerateDevices();
      await this.updateGhostOverlay();
      return true;
    } catch (e) {
      console.error('Camera access error:', e);
      // Fallback: try default video constraint without specific device/facing mode
      try {
        this.stream = await navigator.mediaDevices.getUserMedia({ video: true });
        if (this.videoElement) {
          this.videoElement.srcObject = this.stream;
          await this.videoElement.play();
        }
        return true;
      } catch (err) {
        console.error('Fallback camera failed:', err);
        return false;
      }
    }
  },

  stopSession() {
    if (this.stream) {
      this.stream.getTracks().forEach(track => track.stop());
      this.stream = null;
    }
    if (this.videoElement) {
      this.videoElement.srcObject = null;
    }
  },

  async switchCamera() {
    if (this.availableDevices.length > 1) {
      const currentIndex = this.availableDevices.findIndex(d => d.deviceId === this.currentDeviceId);
      const nextIndex = (currentIndex + 1) % this.availableDevices.length;
      this.currentDeviceId = this.availableDevices[nextIndex].deviceId;
    } else {
      this.facingMode = this.facingMode === 'user' ? 'environment' : 'user';
      this.currentDeviceId = null;
    }
    return this.startSession();
  },

  async setOverlayPhoto(blobOrUrl) {
    if (!blobOrUrl) {
      this.overlayImage = null;
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
        img.src = URL.createObjectURL(blobOrUrl);
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

    const videoW = this.videoElement.videoWidth || this.videoElement.clientWidth || 640;
    const videoH = this.videoElement.videoHeight || this.videoElement.clientHeight || 480;

    canvas.width = videoW;
    canvas.height = videoH;

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (this.isOverlayVisible && this.overlayImage) {
      ctx.globalAlpha = this.overlayOpacity;

      // Aspect-fill / Aspect-fit draw overlay photo
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

  captureFrame() {
    if (!this.videoElement) return null;

    const video = this.videoElement;
    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth || video.clientWidth || 1920;
    canvas.height = video.videoHeight || video.clientHeight || 1080;

    const ctx = canvas.getContext('2d');

    // Flip horizontally if front camera view is mirrored
    if (this.facingMode === 'user' && !this.currentDeviceId) {
      ctx.translate(canvas.width, 0);
      ctx.scale(-1, 1);
    }

    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    return canvas;
  }
};

window.Camera = Camera;
