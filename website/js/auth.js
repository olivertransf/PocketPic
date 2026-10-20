//
// Auth module for PocketPic Web
// The passphrase hash lives in the R2 bucket when using Worker; otherwise falls back to browser local storage.
//

const Auth = {
  LOCAL_KEY: 'pp_passphrase_hash',
  SESSION_KEY: 'pp_unlocked',

  async sha256Hex(value) {
    const encoder = new TextEncoder();
    const data = encoder.encode(value);
    const hash = await crypto.subtle.digest('SHA-256', data);
    return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, '0')).join('');
  },

  async status() {
    try {
      const response = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' });
      if (response.ok) return response.json();
    } catch (e) {
      console.warn('Backend API unavailable, using local browser auth fallback:', e);
    }

    // Local browser fallback
    const storedHash = localStorage.getItem(this.LOCAL_KEY);
    const unlocked = sessionStorage.getItem(this.SESSION_KEY) === 'true';
    return { unlocked, passphraseSet: storedHash !== null };
  },

  async unlock(passphrase) {
    const value = (passphrase || '').trim();
    if (!value) return { ok: false, error: 'Enter a passphrase.' };

    try {
      const response = await fetch('/api/unlock', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ passphrase: value })
      });
      if (response.ok) {
        const body = await response.json();
        return { ok: true, created: !!body.created };
      }
      if (response.status !== 404 && response.status !== 501) {
        const body = await response.json().catch(() => ({}));
        return { ok: false, error: body.error || `Server returned ${response.status}` };
      }
    } catch (e) {
      console.warn('Backend API unavailable, attempting local browser unlock:', e);
    }

    // Local browser fallback
    const hash = await this.sha256Hex(value);
    const storedHash = localStorage.getItem(this.LOCAL_KEY);

    if (!storedHash) {
      localStorage.setItem(this.LOCAL_KEY, hash);
      sessionStorage.setItem(this.SESSION_KEY, 'true');
      return { ok: true, created: true };
    }

    if (storedHash === hash) {
      sessionStorage.setItem(this.SESSION_KEY, 'true');
      return { ok: true, created: false };
    }

    return { ok: false, error: 'Incorrect passphrase.' };
  },

  async setPassphrase(passphrase) {
    const value = (passphrase || '').trim();
    if (!value) return { ok: false, error: 'Passphrase cannot be empty.' };

    try {
      const response = await fetch('/api/passphrase', {
        method: 'PUT',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ passphrase: value })
      });
      if (response.ok) return { ok: true };
      if (response.status !== 404 && response.status !== 501) {
        const body = await response.json().catch(() => ({}));
        return { ok: false, error: body.error || `Server returned ${response.status}` };
      }
    } catch (e) {
      console.warn('Backend API unavailable, setting local browser passphrase:', e);
    }

    // Local browser fallback
    const hash = await this.sha256Hex(value);
    localStorage.setItem(this.LOCAL_KEY, hash);
    sessionStorage.setItem(this.SESSION_KEY, 'true');
    return { ok: true };
  },

  async lock() {
    try {
      await fetch('/api/lock', { method: 'POST', credentials: 'same-origin' });
    } catch (e) {
      console.warn('Lock request failed:', e);
    }
    sessionStorage.removeItem(this.SESSION_KEY);
  }
};

window.Auth = Auth;
