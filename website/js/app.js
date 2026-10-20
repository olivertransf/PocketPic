//
// Main Application Integration module for PocketPic Web
// Controls tab navigation, the passphrase lock screen, background sync, camera controls, settings, and exports.
//

const SYNC_INTERVAL_MS = 30000;

const App = {
  currentTab: 'library',
  isUnlocked: false,
  syncTimer: null,
  galleryReady: false,

  async init() {
    await Storage.init();

    this.setupTabNavigation();
    this.bindLockScreen();
    this.bindCameraControls();
    await this.bindSettings();
    this.bindExport();
    this.bindSyncEvents();

    const videoEl = document.getElementById('viewfinder-video');
    const overlayCanvasEl = document.getElementById('overlay-canvas');
    if (videoEl && overlayCanvasEl) {
      Camera.init(videoEl, overlayCanvasEl).catch(e => console.warn('Camera init warning:', e));
    }

    await this.checkAuth();
  },

  async checkAuth() {
    try {
      const status = await Auth.status();
      if (status.unlocked) {
        await this.onUnlocked();
      } else {
        this.showLock(status.passphraseSet);
      }
    } catch (e) {
      console.warn('Session check failed:', e);
      this.showLock(true, 'Could not reach PocketPic. Check your connection and reload.');
    }
  },

  showLock(passphraseSet = true, errorMessage = '') {
    this.isUnlocked = false;
    this.stopSyncTimer();
    Camera.stopSession();
    document.body.classList.add('locked');

    const overlay = document.getElementById('passphrase-lock-overlay');
    const desc = document.getElementById('unlock-passphrase-desc');
    const button = document.getElementById('unlock-passphrase-btn');
    const errorEl = document.getElementById('unlock-passphrase-error');

    if (desc) {
      desc.textContent = passphraseSet
        ? 'Enter your passphrase to open your journal.'
        : 'Choose a passphrase. Every device will use it to open this journal.';
    }
    if (button) button.textContent = passphraseSet ? 'Unlock Journal' : 'Set Passphrase & Unlock';
    if (errorEl) {
      errorEl.textContent = errorMessage;
      errorEl.style.display = errorMessage ? 'block' : 'none';
    }
    overlay?.classList.add('active');
    document.getElementById('unlock-passphrase-input')?.focus();
  },

  async onUnlocked() {
    this.isUnlocked = true;
    document.body.classList.remove('locked');
    document.getElementById('passphrase-lock-overlay')?.classList.remove('active');

    if (!this.galleryReady) {
      const galleryContainer = document.getElementById('gallery-container');
      if (galleryContainer) await Gallery.init(galleryContainer);
      this.galleryReady = true;
    } else {
      await Gallery.refresh();
    }

    await Camera.updateGhostOverlay();
    if (this.currentTab === 'camera') await this.switchTab('camera');

    Storage.sync().catch(() => {});
    this.startSyncTimer();
  },

  bindLockScreen() {
    const unlockBtn = document.getElementById('unlock-passphrase-btn');
    const inputEl = document.getElementById('unlock-passphrase-input');
    const errorEl = document.getElementById('unlock-passphrase-error');
    if (!unlockBtn || !inputEl) return;

    const attemptUnlock = async () => {
      unlockBtn.disabled = true;
      const result = await Auth.unlock(inputEl.value);
      unlockBtn.disabled = false;

      if (result.ok) {
        inputEl.value = '';
        if (errorEl) errorEl.style.display = 'none';
        await this.onUnlocked();
      } else if (errorEl) {
        errorEl.textContent = result.error;
        errorEl.style.display = 'block';
      }
    };

    unlockBtn.addEventListener('click', attemptUnlock);
    inputEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') attemptUnlock();
    });
  },

  bindSyncEvents() {
    window.addEventListener('pocketpic:locked', () => this.showLock(true, 'Your session ended. Enter your passphrase again.'));

    window.addEventListener('pocketpic:photos-changed', async () => {
      if (!this.isUnlocked) return;
      await Gallery.refresh();
      await Camera.updateGhostOverlay();
    });

    window.addEventListener('pocketpic:sync-status', () => {
      if (this.isUnlocked && this.galleryReady) Gallery.render();
      this.renderSyncStatus();
    });

    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && this.isUnlocked) Storage.sync().catch(() => {});
    });

    window.addEventListener('online', () => {
      if (this.isUnlocked) Storage.sync().catch(() => {});
    });
  },

  startSyncTimer() {
    this.stopSyncTimer();
    this.syncTimer = setInterval(() => {
      if (document.visibilityState === 'visible' && this.isUnlocked) Storage.sync().catch(() => {});
    }, SYNC_INTERVAL_MS);
  },

  stopSyncTimer() {
    if (this.syncTimer) clearInterval(this.syncTimer);
    this.syncTimer = null;
  },

  renderSyncStatus() {
    const statusEl = document.getElementById('settings-sync-status');
    if (!statusEl) return;
    switch (Storage.syncState) {
      case 'syncing':
        statusEl.textContent = 'Syncing…';
        break;
      case 'error':
        statusEl.textContent = `Last sync failed: ${Storage.syncMessage}`;
        break;
      case 'locked':
        statusEl.textContent = 'Locked.';
        break;
      default:
        statusEl.textContent = Storage.lastSyncedAt
          ? `Last synced ${Storage.lastSyncedAt.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}.`
          : 'Not synced yet.';
    }
  },

  setupTabNavigation() {
    document.querySelectorAll('.nav-btn').forEach(btn => {
      btn.addEventListener('click', () => this.switchTab(btn.dataset.tab));
    });

    document.getElementById('header-lock-btn')?.addEventListener('click', async () => {
      await Auth.lock();
      this.showLock(true);
    });
  },

  async switchTab(tabName) {
    this.currentTab = tabName;

    document.querySelectorAll('.nav-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tab === tabName);
    });
    document.querySelectorAll('.tab-pane').forEach(pane => {
      pane.classList.toggle('active', pane.id === `tab-${tabName}`);
    });
    document.body.dataset.tab = tabName;

    if (tabName === 'camera' && this.isUnlocked) {
      const started = await Camera.startSession();
      if (!started) alert('Could not access the camera. Allow camera access for this site in your browser settings.');
    } else {
      Camera.stopSession();
    }

    if (tabName === 'library' && this.galleryReady) {
      await Gallery.refresh();
    }
  },

  bindCameraControls() {
    const shutterBtn = document.getElementById('camera-shutter-btn');
    if (shutterBtn) {
      shutterBtn.addEventListener('click', async () => {
        const frameCanvas = Camera.captureFrame();
        if (!frameCanvas) return;

        const viewfinder = document.querySelector('.viewfinder-wrapper');
        if (viewfinder) {
          viewfinder.style.opacity = '0.3';
          setTimeout(() => { viewfinder.style.opacity = '1'; }, 100);
        }

        shutterBtn.disabled = true;
        try {
          await Storage.savePhoto(frameCanvas);
        } catch (e) {
          alert(`Could not save photo: ${e.message}`);
        } finally {
          shutterBtn.disabled = false;
        }
      });
    }

    document.getElementById('camera-switch-btn')?.addEventListener('click', async () => {
      await Camera.switchCamera();
    });

    const toggleOverlayBtn = document.getElementById('camera-overlay-btn');
    if (toggleOverlayBtn) {
      toggleOverlayBtn.classList.toggle('active', Camera.isOverlayVisible);
      toggleOverlayBtn.addEventListener('click', () => {
        const isVisible = Camera.toggleOverlay();
        toggleOverlayBtn.classList.toggle('active', isVisible);
      });
    }

    const opacityRange = document.getElementById('camera-opacity-range');
    if (opacityRange) {
      Storage.getSetting('overlayOpacity', 0.4).then((value) => { opacityRange.value = value; });
      opacityRange.addEventListener('input', (e) => {
        Camera.setOverlayOpacity(parseFloat(e.target.value));
      });
    }
  },

  async bindSettings() {
    const setPassphraseBtn = document.getElementById('settings-save-passphrase');
    const passphraseInput = document.getElementById('settings-passphrase-input');

    if (setPassphraseBtn && passphraseInput) {
      passphraseInput.value = '';
      setPassphraseBtn.addEventListener('click', async () => {
        if (!passphraseInput.value.trim()) {
          alert('Enter a new passphrase.');
          return;
        }
        if (!confirm('Change the passphrase on every device? Other devices will need the new one.')) return;
        const result = await Auth.setPassphrase(passphraseInput.value);
        passphraseInput.value = '';
        alert(result.ok ? 'Passphrase changed.' : `Could not change passphrase: ${result.error}`);
      });
    }

    const settingsOpacityRange = document.getElementById('settings-opacity-range');
    if (settingsOpacityRange) {
      settingsOpacityRange.value = await Storage.getSetting('overlayOpacity', 0.4);
      settingsOpacityRange.addEventListener('input', async (e) => {
        const opacity = parseFloat(e.target.value);
        Camera.setOverlayOpacity(opacity);
        const cameraRange = document.getElementById('camera-opacity-range');
        if (cameraRange) cameraRange.value = opacity;
      });
    }

    const qualitySelect = document.getElementById('settings-quality-select');
    if (qualitySelect) {
      qualitySelect.value = await Storage.getSetting('compressionQuality', 0.85);
      qualitySelect.addEventListener('change', async (e) => {
        await Storage.setSetting('compressionQuality', parseFloat(e.target.value));
      });
    }

    document.getElementById('settings-sync-now')?.addEventListener('click', () => {
      Storage.sync().catch(() => {});
    });
    this.renderSyncStatus();
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
