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

    let html = `
      <div class="gallery-header-bar">
        <div class="gallery-stats">
          <div class="stat-badge">
            <span class="stat-value">${this.photos.length}</span>
            <span class="stat-label">Photos</span>
          </div>
          <div class="stat-badge">
            <span class="stat-value">${currentStreak}</span>
            <span class="stat-label">Day Streak</span>
          </div>
          <div class="stat-badge">
            <span class="stat-value">${longestStreak}</span>
            <span class="stat-label">Best Streak</span>
          </div>
        </div>

        <div class="gallery-actions">
          <button class="btn btn-secondary ${Storage.syncState === 'error' ? 'sync-error' : ''}" id="gallery-sync" title="${Storage.syncMessage || 'Sync with your other devices'}">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="${Storage.syncState === 'syncing' ? 'spin' : ''}"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
            ${this.syncLabel()}
          </button>

          <button class="btn btn-secondary ${this.isPrivacyMode ? 'active' : ''}" id="gallery-privacy-toggle" title="Toggle Privacy Mode">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>
            ${this.isPrivacyMode ? 'Hidden' : 'Hide'}
          </button>

          <button class="btn btn-secondary ${this.isSelectionMode ? 'active' : ''}" id="gallery-select-toggle">
            ${this.isSelectionMode ? 'Cancel' : 'Select'}
          </button>

          ${this.isSelectionMode ? `
            <button class="btn btn-secondary" id="gallery-select-all">
              ${this.selectedPhotoIds.size === this.photos.length ? 'Deselect All' : 'Select All'}
            </button>
            <button class="btn btn-danger" id="gallery-delete-selected" ${this.selectedPhotoIds.size === 0 ? 'disabled' : ''}>
              Delete (${this.selectedPhotoIds.size})
            </button>
          ` : ''}
        </div>
      </div>
    `;

    if (this.photos.length === 0) {
      html += `
        <div class="empty-state">
          <div class="empty-icon">
            <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/></svg>
          </div>
          <h3 style="font-size: 1.3rem; font-weight: 600; margin-bottom: 6px;">No Photos Yet</h3>
          <p style="color: var(--text-secondary); font-size: 0.9rem; margin-bottom: 20px;">Take today’s photo. Photos from your other devices appear here after they sync.</p>
          <div style="display: flex; gap: 10px; flex-wrap: wrap; justify-content: center;">
            <button class="btn btn-primary" onclick="App.switchTab('camera')">Open Camera</button>
            <button class="btn btn-secondary" onclick="Gallery.syncNow()">Sync Now</button>
          </div>
        </div>
      `;
    } else {
      html += `<div class="gallery-grid-wrapper">`;

      for (const [monthKey, monthPhotos] of Object.entries(photoGroups)) {
        html += `
          <div class="month-section">
            <h3 class="month-title">${monthKey}</h3>
            <div class="mosaic-grid">
        `;

        for (const photo of monthPhotos) {
          const isSelected = this.selectedPhotoIds.has(photo.id);
          const imgUrl = this.isPrivacyMode ? '' : this.photoUrl(photo);

          html += `
            <div class="mosaic-tile ${isSelected ? 'selected' : ''} ${photo.pending ? 'pending' : ''}" data-id="${photo.id}">
              ${this.isPrivacyMode ? `
                <div class="privacy-placeholder">
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>
                </div>
              ` : `
                <img src="${imgUrl}" alt="Photo ${new Date(photo.date).toLocaleDateString()}" loading="lazy">
              `}
              ${this.isSelectionMode ? `
                <div class="selection-badge ${isSelected ? 'checked' : ''}">
                  ${isSelected ? '✓' : ''}
                </div>
              ` : ''}
              <div class="tile-date">${new Date(photo.date).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}</div>
            </div>
          `;
        }

        html += `
            </div>
          </div>
        `;
      }

      html += `</div>`;
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
      tile.addEventListener('click', () => {
        if (this.isSelectionMode) {
          this.toggleSelectPhoto(id);
        } else {
          this.openDetailModal(id);
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
      modal.className = 'modal-overlay';
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
      <div class="modal-content photo-detail-content">
        <button class="modal-close" id="detail-close">&times;</button>
        <div class="photo-detail-frame">
          ${prevPhoto ? `<button class="nav-arrow nav-arrow-left" id="detail-prev-btn" title="Older Photo">&lsaquo;</button>` : ''}
          <img src="${imgUrl}" alt="Full Photo">
          ${nextPhoto ? `<button class="nav-arrow nav-arrow-right" id="detail-next-btn" title="Newer Photo">&rsaquo;</button>` : ''}
        </div>
        <div class="photo-detail-meta">
          <div class="meta-date" style="font-size: 0.88rem; color: var(--text-primary); font-weight: 500;">
            ${formattedDate}
          </div>
          <div class="meta-actions">
            <button class="btn btn-secondary" id="detail-detect-eyes">Detect Eyes</button>
            <label class="btn btn-secondary" for="detail-replace-input">Replace</label>
            <input type="file" id="detail-replace-input" accept="image/*" hidden>
            <button class="btn btn-danger" id="detail-delete">Delete</button>
          </div>
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
