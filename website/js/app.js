//
// Main Application Integration module for PocketPic Web
// Controls tab navigation, event listeners, camera setup, settings, passphrase lock screen, and exports.
//

const App = {
  currentTab: 'library',

  async init() {
    try {
      // 1. Initialize Storage DB
      await Storage.init();
    } catch (e) {
      console.error('Storage init error:', e);
    }

    // 2. Check Passphrase Lock State
    this.checkAuth();

    // 3. Initialize App Navigation
    this.setupTabNavigation();

    // 4. Initialize Gallery first so initial Library view renders immediately
    const galleryContainer = document.getElementById('gallery-container');
    if (galleryContainer) {
      try {
        await Gallery.init(galleryContainer);
      } catch (e) {
        console.error('Gallery init error:', e);
      }
    }

    // 5. Initialize Camera & Viewfinder asynchronously (non-blocking)
    const videoEl = document.getElementById('viewfinder-video');
    const overlayCanvasEl = document.getElementById('overlay-canvas');
    if (videoEl && overlayCanvasEl) {
      Camera.init(videoEl, overlayCanvasEl).catch(e => console.warn('Camera init non-blocking warning:', e));
    }

    // 6. Bind Camera Controls
    this.bindCameraControls();

    // 7. Bind Settings & Passphrase UI
    this.bindSettings();

    // 8. Bind Export UI
    this.bindExport();
  },

  checkAuth() {
    const lockOverlay = document.getElementById('passphrase-lock-overlay');
    if (!lockOverlay) return;

    if (Auth.isUnlocked()) {
      lockOverlay.classList.remove('active');
    } else {
      lockOverlay.classList.add('active');
      this.bindLockScreen();
    }
  },

  bindLockScreen() {
    const unlockBtn = document.getElementById('unlock-passphrase-btn');
    const inputEl = document.getElementById('unlock-passphrase-input');
    const errorEl = document.getElementById('unlock-passphrase-error');

    if (!unlockBtn || !inputEl) return;

    const attemptUnlock = async () => {
      const success = await Auth.unlock(inputEl.value);
      if (success) {
        document.getElementById('passphrase-lock-overlay').classList.remove('active');
        inputEl.value = '';
        if (errorEl) errorEl.style.display = 'none';
      } else {
        if (errorEl) {
          errorEl.textContent = 'Incorrect passphrase. Try again.';
          errorEl.style.display = 'block';
        }
      }
    };

    unlockBtn.onclick = attemptUnlock;
    inputEl.onkeyup = (e) => {
      if (e.key === 'Enter') attemptUnlock();
    };
  },

  setupTabNavigation() {
    const navButtons = document.querySelectorAll('.nav-btn');
    navButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        const tab = btn.dataset.tab;
        this.switchTab(tab);
      });
    });

    const lockBtn = document.getElementById('header-lock-btn');
    if (lockBtn) {
      lockBtn.addEventListener('click', () => {
        Auth.lock();
        this.checkAuth();
      });
    }
  },

  async switchTab(tabName) {
    this.currentTab = tabName;

    // Update nav button active classes
    document.querySelectorAll('.nav-btn').forEach(btn => {
      if (btn.dataset.tab === tabName) btn.classList.add('active');
      else btn.classList.remove('active');
    });

    // Update tab pane visibility
    document.querySelectorAll('.tab-pane').forEach(pane => {
      if (pane.id === `tab-${tabName}`) pane.classList.add('active');
      else pane.classList.remove('active');
    });

    // Handle camera session lifecycle
    if (tabName === 'camera') {
      try {
        await Camera.startSession();
      } catch (e) {
        alert('Could not access camera. Please allow camera permissions in browser settings.');
      }
    } else {
      Camera.stopSession();
    }

    // Refresh gallery if switching back to library
    if (tabName === 'library') {
      await Gallery.refresh();
    }
  },

  bindCameraControls() {
    const shutterBtn = document.getElementById('camera-shutter-btn');
    if (shutterBtn) {
      shutterBtn.addEventListener('click', async () => {
        const frameCanvas = Camera.captureFrame();
        if (frameCanvas) {
          // Save captured frame directly to IndexedDB
          await Storage.savePhoto(frameCanvas);
          // Refresh overlay and gallery
          await Camera.updateGhostOverlay();
          await Gallery.refresh();

          // Flash effect
          const viewfinder = document.querySelector('.viewfinder-wrapper');
          if (viewfinder) {
            viewfinder.style.opacity = '0.3';
            setTimeout(() => { viewfinder.style.opacity = '1'; }, 100);
          }
        }
      });
    }

    const switchCamBtn = document.getElementById('camera-switch-btn');
    if (switchCamBtn) {
      switchCamBtn.addEventListener('click', async () => {
        await Camera.switchCamera();
      });
    }

    const toggleOverlayBtn = document.getElementById('camera-overlay-btn');
    if (toggleOverlayBtn) {
      toggleOverlayBtn.addEventListener('click', () => {
        const isVisible = Camera.toggleOverlay();
        toggleOverlayBtn.classList.toggle('active', isVisible);
      });
    }

    const opacityRange = document.getElementById('camera-opacity-range');
    if (opacityRange) {
      opacityRange.value = Camera.overlayOpacity;
      opacityRange.addEventListener('input', (e) => {
        const opacity = parseFloat(e.target.value);
        Camera.setOverlayOpacity(opacity);
      });
    }
  },

  async bindSettings() {
    // Passphrase Settings
    const setPassphraseBtn = document.getElementById('settings-save-passphrase');
    const passphraseInput = document.getElementById('settings-passphrase-input');

    if (setPassphraseBtn && passphraseInput) {
      passphraseInput.value = '';
      setPassphraseBtn.addEventListener('click', async () => {
        const val = passphraseInput.value;
        await Auth.setPassphrase(val);
        alert(val ? 'Passphrase protection enabled!' : 'Passphrase removed.');
        passphraseInput.value = '';
      });
    }

    // Overlay Opacity Setting
    const settingsOpacityRange = document.getElementById('settings-opacity-range');
    if (settingsOpacityRange) {
      settingsOpacityRange.value = await Storage.getSetting('overlayOpacity', 0.4);
      settingsOpacityRange.addEventListener('input', async (e) => {
        const opacity = parseFloat(e.target.value);
        await Storage.setSetting('overlayOpacity', opacity);
        Camera.setOverlayOpacity(opacity);
      });
    }

    // Compression Quality Setting
    const qualitySelect = document.getElementById('settings-quality-select');
    if (qualitySelect) {
      qualitySelect.value = await Storage.getSetting('compressionQuality', 0.85);
      qualitySelect.addEventListener('change', async (e) => {
        await Storage.setSetting('compressionQuality', parseFloat(e.target.value));
      });
    }

    // Cloudflare R2 Settings
    const r2EndpointInput = document.getElementById('settings-r2-endpoint');
    const r2AccessKeyInput = document.getElementById('settings-r2-access-key');
    const r2SecretKeyInput = document.getElementById('settings-r2-secret-key');
    const r2BucketInput = document.getElementById('settings-r2-bucket');
    const r2SaveBtn = document.getElementById('settings-save-r2');

    if (r2EndpointInput) r2EndpointInput.value = await Storage.getSetting('r2Endpoint', '');
    if (r2AccessKeyInput) r2AccessKeyInput.value = await Storage.getSetting('r2AccessKey', '');
    if (r2SecretKeyInput) r2SecretKeyInput.value = await Storage.getSetting('r2SecretKey', '');
    if (r2BucketInput) r2BucketInput.value = await Storage.getSetting('r2Bucket', 'pocket-pic');

    if (r2SaveBtn) {
      r2SaveBtn.addEventListener('click', async () => {
        await Storage.setSetting('r2Endpoint', r2EndpointInput.value.trim());
        await Storage.setSetting('r2AccessKey', r2AccessKeyInput.value.trim());
        await Storage.setSetting('r2SecretKey', r2SecretKeyInput.value.trim());
        await Storage.setSetting('r2Bucket', r2BucketInput.value.trim());
        alert('Cloudflare R2 bucket configuration saved!');
      });
    }
  },

  bindExport() {
    let selectedFPS = 10;
    const fpsButtons = document.querySelectorAll('.fps-btn');
    fpsButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        fpsButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        selectedFPS = parseInt(btn.dataset.fps, 10);
      });
    });

    const startExportBtn = document.getElementById('start-export-btn');
    const alignEyesToggle = document.getElementById('export-align-eyes-toggle');
    const progressBox = document.getElementById('export-progress-box');
    const progressFill = document.getElementById('export-progress-fill');
    const progressStatus = document.getElementById('export-progress-status');
    const resultBox = document.getElementById('export-result-box');
    const downloadBtn = document.getElementById('export-download-btn');
    const videoPreview = document.getElementById('export-video-preview');

    if (startExportBtn) {
      startExportBtn.addEventListener('click', async () => {
        const photos = await Storage.getAllPhotos();
        if (photos.length === 0) {
          alert('No photos available to export. Snap some photos first!');
          return;
        }

        const alignEyes = alignEyesToggle ? alignEyesToggle.checked : true;

        if (progressBox) progressBox.style.display = 'block';
        if (resultBox) resultBox.style.display = 'none';
        startExportBtn.disabled = true;

        try {
          const exportResult = await Exporter.exportVideo({
            photos,
            fps: selectedFPS,
            alignEyes,
            progressCallback: (percent, statusMsg) => {
              if (progressFill) progressFill.style.width = `${Math.round(percent * 100)}%`;
              if (progressStatus) progressStatus.textContent = statusMsg;
            }
          });

          if (resultBox && downloadBtn && videoPreview) {
            videoPreview.src = exportResult.url;
            downloadBtn.href = exportResult.url;
            downloadBtn.download = exportResult.filename;
            resultBox.style.display = 'block';
          }
        } catch (err) {
          alert(`Export failed: ${err.message}`);
        } finally {
          startExportBtn.disabled = false;
        }
      });
    }
  }
};

window.App = App;

document.addEventListener('DOMContentLoaded', () => {
  App.init();
});
