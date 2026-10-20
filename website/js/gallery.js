//
// Gallery module for PocketPic Web
// Renders photo mosaic grouped by month, streak counters, multi-select bulk delete, privacy mode, and full-screen detail viewer with minimal SVG icons and R2 sync.
//

const Gallery = {
  containerElement: null,
  photos: [],
  selectedPhotoIds: new Set(),
  isSelectionMode: false,
  isPrivacyMode: false,
  objectUrls: new Map(),

  async init(containerEl) {
    this.containerElement = containerEl;
    if (window.Storage) {
      this.isPrivacyMode = await Storage.getSetting('hidePhotosInGallery', false);
    }
    document.addEventListener('keydown', (e) => {
      if (!document.getElementById('photo-detail-modal')?.classList.contains('active')) return;
      if (e.key === 'Escape') this.closeDetailModal();
      if (e.key === 'ArrowLeft') document.getElementById('detail-prev-btn')?.click();
      if (e.key === 'ArrowRight') document.getElementById('detail-next-btn')?.click();
    });
    await this.refresh();
  },

  async refresh() {
    if (window.Storage) {
      this.photos = await Storage.getAllPhotos();
    } else {
      this.photos = [];
    }
    this.pruneObjectUrls();
    this.render();
  },

  calculateStreaks() {
    if (!this.photos || this.photos.length === 0) {
      return { currentStreak: 0, longestStreak: 0 };
    }

    const uniqueDays = new Set(
      this.photos.map(p => {
        const d = new Date(p.date);
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      })
    );

    let currentStreak = 0;
    const today = new Date();
    const todayStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;

    const yesterday = new Date();
    yesterday.setDate(yesterday.getDate() - 1);
    const yesterdayStr = `${yesterday.getFullYear()}-${String(yesterday.getMonth() + 1).padStart(2, '0')}-${String(yesterday.getDate()).padStart(2, '0')}`;

    let checkDate = uniqueDays.has(todayStr) ? new Date(today) : (uniqueDays.has(yesterdayStr) ? new Date(yesterday) : null);

    if (checkDate) {
      while (true) {
        const dateStr = `${checkDate.getFullYear()}-${String(checkDate.getMonth() + 1).padStart(2, '0')}-${String(checkDate.getDate()).padStart(2, '0')}`;
        if (uniqueDays.has(dateStr)) {
          currentStreak++;
          checkDate.setDate(checkDate.getDate() - 1);
        } else {
          break;
        }
      }
    }

    let longestStreak = 0;
    let tempStreak = 0;
    const ascDays = Array.from(uniqueDays).sort();

    for (let i = 0; i < ascDays.length; i++) {
      if (i === 0) {
        tempStreak = 1;
      } else {
        const prev = new Date(ascDays[i - 1]);
        const curr = new Date(ascDays[i]);
        const diffTime = Math.abs(curr - prev);
        const diffDays = Math.round(diffTime / (1000 * 60 * 60 * 24));

        if (diffDays === 1) {
          tempStreak++;
        } else {
          tempStreak = 1;
        }
      }
      longestStreak = Math.max(longestStreak, tempStreak);
    }

    return { currentStreak, longestStreak };
  },

  groupPhotosByMonth() {
    const groups = {};
    const monthNames = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];

    for (const photo of this.photos) {
      const d = new Date(photo.date);
      const key = `${monthNames[d.getMonth()]} ${d.getFullYear()}`;
      if (!groups[key]) groups[key] = [];
      groups[key].push(photo);
    }

    return groups;
  },

  syncNow() {
    if (window.Storage) Storage.sync().catch(() => {});
  },

  photoUrl(photo) {
    const version = `${photo.updatedAt || 'local'}:${photo.blob.size}`;
    const cached = this.objectUrls.get(photo.id);
    if (cached && cached.version === version) return cached.url;
    if (cached) URL.revokeObjectURL(cached.url);
    const url = URL.createObjectURL(photo.blob);
    this.objectUrls.set(photo.id, { version, url });
    return url;
  },

  pruneObjectUrls() {
    const ids = new Set(this.photos.map((photo) => photo.id));
    for (const [id, cached] of this.objectUrls) {
      if (!ids.has(id)) {
        URL.revokeObjectURL(cached.url);
        this.objectUrls.delete(id);
      }
    }
  },

  syncLabel() {
    switch (Storage.syncState) {
      case 'syncing':
        return 'Syncing…';
      case 'error':
        return 'Sync failed';
      case 'locked':
        return 'Locked';
      default:
        return 'Sync';
    }
  },

  async togglePrivacyMode(enabled = null) {
    this.isPrivacyMode = enabled !== null ? enabled : !this.isPrivacyMode;
    if (window.Storage) {
      await Storage.setSetting('hidePhotosInGallery', this.isPrivacyMode);
    }
    this.render();
  },

  toggleSelectionMode(enabled = null) {
    this.isSelectionMode = enabled !== null ? enabled : !this.isSelectionMode;
    if (!this.isSelectionMode) {
      this.selectedPhotoIds.clear();
    }
    this.render();
  },

  toggleSelectPhoto(photoId) {
    if (this.selectedPhotoIds.has(photoId)) {
      this.selectedPhotoIds.delete(photoId);
    } else {
      this.selectedPhotoIds.add(photoId);
    }
    this.render();
  },

  selectAll() {
    if (this.selectedPhotoIds.size === this.photos.length) {
      this.selectedPhotoIds.clear();
    } else {
      this.photos.forEach(p => this.selectedPhotoIds.add(p.id));
    }
    this.render();
  },

  async deleteSelected() {
    if (this.selectedPhotoIds.size === 0) return;
    if (confirm(`Delete ${this.selectedPhotoIds.size} selected photo(s)?`)) {
      try {
        await Storage.deletePhotos(Array.from(this.selectedPhotoIds));
      } catch (e) {
        if (!(e instanceof LockedError)) alert(`Could not delete: ${e.message}`);
        return;
      }
      this.selectedPhotoIds.clear();
      this.isSelectionMode = false;
      await this.refresh();
    }
  },

  async deleteSinglePhoto(id) {
    if (confirm('Are you sure you want to delete this photo?')) {
      try {
        await Storage.deletePhoto(id);
      } catch (e) {
        if (!(e instanceof LockedError)) alert(`Could not delete: ${e.message}`);
        return;
      }
      this.closeDetailModal();
    }
  },

  async replaceSinglePhoto(id, file) {
    if (!file) return;
    try {
      await Storage.replacePhoto(id, file);
      this.closeDetailModal();
    } catch (e) {
      alert(`Could not replace photo: ${e.message}`);
    }
  },

  render() {
    if (!this.containerElement) return;

    const { currentStreak, longestStreak } = this.calculateStreaks();
    const photoGroups = this.groupPhotosByMonth();
    const count = this.photos.length;
    const syncing = Storage.syncState === 'syncing';
    const syncFailed = Storage.syncState === 'error';

    const subtitle = [
      `${count} ${count === 1 ? 'photo' : 'photos'}`,
      currentStreak > 0 ? `${currentStreak}-day streak` : null,
      longestStreak > 1 ? `best ${longestStreak}` : null
    ].filter(Boolean).join(' · ');

    let html = `
      <div class="page-header">
        <div>
          <h1 class="page-title">Library</h1>
          <p class="page-subtitle">${subtitle}${syncFailed ? ' · <span class="sync-error">Sync failed</span>' : ''}</p>
        </div>
        <div class="toolbar">
          <button class="icon-btn ${syncFailed ? 'sync-error' : ''}" id="gallery-sync" title="${Storage.syncMessage || this.syncLabel()}" aria-label="${this.syncLabel()}">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" class="${syncing ? 'spin' : ''}"><path d="M20 11a8 8 0 0 0-14.3-4.9L4 8"/><path d="M4 4v4h4"/><path d="M4 13a8 8 0 0 0 14.3 4.9L20 16"/><path d="M20 20v-4h-4"/></svg>
          </button>
          <button class="icon-btn ${this.isPrivacyMode ? 'active' : ''}" id="gallery-privacy-toggle" title="${this.isPrivacyMode ? 'Show photos' : 'Hide photos'}" aria-label="${this.isPrivacyMode ? 'Show photos' : 'Hide photos'}">
            ${this.isPrivacyMode
              ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3l18 18"/><path d="M10.6 5.1A9.7 9.7 0 0 1 12 5c6 0 9.5 7 9.5 7a16.6 16.6 0 0 1-2.6 3.5M6.6 6.6A16.4 16.4 0 0 0 2.5 12s3.5 7 9.5 7a9.4 9.4 0 0 0 5.4-1.6"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>'
              : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7-9.5-7-9.5-7z"/><circle cx="12" cy="12" r="3"/></svg>'}
          </button>
          ${count > 0 ? `
            <button class="btn btn-pill ${this.isSelectionMode ? 'active' : ''}" id="gallery-select-toggle">
              ${this.isSelectionMode ? 'Done' : 'Select'}
            </button>
          ` : ''}
        </div>
      </div>
    `;

    if (this.isSelectionMode) {
      const selected = this.selectedPhotoIds.size;
      html += `
        <div class="selection-bar">
          <button class="btn btn-plain" id="gallery-select-all">
            ${selected === count ? 'Deselect All' : 'Select All'}
          </button>
          <span class="selection-count">${selected === 0 ? 'Select Items' : `${selected} Selected`}</span>
          <button class="btn btn-plain danger" id="gallery-delete-selected" ${selected === 0 ? 'disabled' : ''}>Delete</button>
        </div>
      `;
    }

    if (count === 0) {
      html += `
        <div class="empty-state">
          <div class="empty-icon">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8.5A2.5 2.5 0 0 1 5.5 6h1.8l1.5-2h6.4l1.5 2h1.8A2.5 2.5 0 0 1 21 8.5v9a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/><circle cx="12" cy="13" r="3.5"/></svg>
          </div>
          <h2>No Photos Yet</h2>
          <p>Take today’s photo. Photos from your other devices appear here after they sync.</p>
          <div class="empty-actions">
            <button class="btn btn-primary" onclick="App.switchTab('camera')">Open Camera</button>
            <button class="btn btn-plain" onclick="Gallery.syncNow()">Sync Now</button>
          </div>
        </div>
      `;
    } else {
      for (const [monthKey, monthPhotos] of Object.entries(photoGroups)) {
        html += `
          <section class="month-section">
            <h2 class="month-title">${monthKey}</h2>
            <div class="mosaic-grid">
        `;

        for (const photo of monthPhotos) {
          const isSelected = this.selectedPhotoIds.has(photo.id);
          const date = new Date(photo.date);

          html += `
            <div class="mosaic-tile ${isSelected ? 'selected' : ''} ${photo.pending ? 'pending' : ''}" data-id="${photo.id}" role="button" tabindex="0">
              ${this.isPrivacyMode ? `
                <div class="privacy-placeholder"></div>
              ` : `
                <img src="${this.photoUrl(photo)}" alt="Photo ${date.toLocaleDateString()}" loading="lazy" decoding="async">
              `}
              <span class="tile-date">${date.getDate()}</span>
              ${this.isSelectionMode ? `
                <span class="selection-badge ${isSelected ? 'checked' : ''}">
                  ${isSelected ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>' : ''}
                </span>
              ` : ''}
            </div>
          `;
        }

        html += `
            </div>
          </section>
        `;
      }
    }

    this.containerElement.innerHTML = html;
    this.attachEvents();
  },

  attachEvents() {
    const syncBtn = document.getElementById('gallery-sync');
    if (syncBtn) {
      syncBtn.addEventListener('click', () => this.syncNow());
    }

    const privacyBtn = document.getElementById('gallery-privacy-toggle');
    if (privacyBtn) {
      privacyBtn.addEventListener('click', () => this.togglePrivacyMode());
    }

    const selectBtn = document.getElementById('gallery-select-toggle');
    if (selectBtn) {
      selectBtn.addEventListener('click', () => this.toggleSelectionMode());
    }

    const selectAllBtn = document.getElementById('gallery-select-all');
    if (selectAllBtn) {
      selectAllBtn.addEventListener('click', () => this.selectAll());
    }

    const deleteSelBtn = document.getElementById('gallery-delete-selected');
    if (deleteSelBtn) {
      deleteSelBtn.addEventListener('click', () => this.deleteSelected());
    }

    const tiles = this.containerElement.querySelectorAll('.mosaic-tile');
    tiles.forEach(tile => {
      const id = tile.dataset.id;
      const activate = () => {
        if (this.isSelectionMode) {
          this.toggleSelectPhoto(id);
        } else {
          this.openDetailModal(id);
        }
      };
      tile.addEventListener('click', activate);
      tile.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          activate();
        }
      });
    });
  },

  async openDetailModal(photoId) {
    if (!window.Storage) return;

    const currentIndex = this.photos.findIndex(p => p.id === photoId);
    if (currentIndex === -1) return;

    const photo = this.photos[currentIndex];
    const prevPhoto = currentIndex < this.photos.length - 1 ? this.photos[currentIndex + 1] : null;
    const nextPhoto = currentIndex > 0 ? this.photos[currentIndex - 1] : null;

    let modal = document.getElementById('photo-detail-modal');
    if (!modal) {
      modal = document.createElement('div');
      modal.id = 'photo-detail-modal';
      modal.className = 'modal-overlay photo-viewer';
      document.body.appendChild(modal);
    }

    const imgUrl = this.photoUrl(photo);
    const formattedDate = new Date(photo.date).toLocaleDateString(undefined, {
      weekday: 'long',
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });

    modal.innerHTML = `
      <div class="photo-detail-content">
        <div class="photo-detail-top">
          <div class="meta-date">${formattedDate}</div>
          <button class="icon-btn glass" id="detail-close" aria-label="Close">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>
          </button>
        </div>
        <div class="photo-detail-frame">
          <img src="${imgUrl}" alt="Photo from ${formattedDate}">
          ${prevPhoto ? `<button class="icon-btn glass nav-arrow nav-arrow-left" id="detail-prev-btn" title="Older photo" aria-label="Older photo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg></button>` : ''}
          ${nextPhoto ? `<button class="icon-btn glass nav-arrow nav-arrow-right" id="detail-next-btn" title="Newer photo" aria-label="Newer photo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg></button>` : ''}
        </div>
        <div class="meta-actions">
          <button class="btn btn-glass" id="detail-detect-eyes">Detect Eyes</button>
          <label class="btn btn-glass" for="detail-replace-input">Replace</label>
          <input type="file" id="detail-replace-input" accept="image/*" hidden>
          <button class="btn btn-glass danger" id="detail-delete">Delete</button>
        </div>
      </div>
    `;

    modal.classList.add('active');

    document.getElementById('detail-close').onclick = () => this.closeDetailModal();
    document.getElementById('detail-delete').onclick = () => this.deleteSinglePhoto(photo.id);
    document.getElementById('detail-replace-input').onchange = (e) => this.replaceSinglePhoto(photo.id, e.target.files[0]);

    if (prevPhoto) {
      document.getElementById('detail-prev-btn').onclick = () => this.openDetailModal(prevPhoto.id);
    }
    if (nextPhoto) {
      document.getElementById('detail-next-btn').onclick = () => this.openDetailModal(nextPhoto.id);
    }

    document.getElementById('detail-detect-eyes').onclick = async () => {
      if (window.EyeDetection) {
        const eyes = await EyeDetection.detectEyes(photo.blob);
        if (eyes) {
          alert(`Eyes detected successfully!\nLeft eye: (${Math.round(eyes.leftEye.x)}, ${Math.round(eyes.leftEye.y)})\nRight eye: (${Math.round(eyes.rightEye.x)}, ${Math.round(eyes.rightEye.y)})`);
        } else {
          alert('No eyes / face landmarks detected in this photo.');
        }
      }
    };

    modal.onclick = (e) => {
      if (e.target === modal) this.closeDetailModal();
    };
  },

  closeDetailModal() {
    const modal = document.getElementById('photo-detail-modal');
    if (modal) {
      modal.classList.remove('active');
    }
  }
};

window.Gallery = Gallery;
