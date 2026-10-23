//
// Auth module for PocketPic Web
// Browser-side passphrase authentication using Web Crypto SHA-256 and local storage.
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
    const storedHash = localStorage.getItem(this.LOCAL_KEY);

    try {
      const res = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' });
      if (res.ok) {
        const data = await res.json();
        // The Worker session is the source of truth. A leftover local flag must not
        // keep the journal open after the session expired: the API then rejects every
        // photo request and the library looks empty with no passphrase prompt.
        if (!data.unlocked) {
          localStorage.removeItem(this.SESSION_KEY);
          sessionStorage.removeItem(this.SESSION_KEY);
        }
        return {
          unlocked: Boolean(data.unlocked),
          passphraseSet: Boolean(data.passphraseSet ?? storedHash !== null)
        };
      }
    } catch {
      // Backend API not reachable; fall back to local storage auth
    }

    const localUnlocked = localStorage.getItem(this.SESSION_KEY) === 'true' || sessionStorage.getItem(this.SESSION_KEY) === 'true';
    return { unlocked: localUnlocked, passphraseSet: storedHash !== null };
  },

  async unlock(passphrase) {
    const value = (passphrase || '').trim();
    if (!value) return { ok: false, error: 'Enter a passphrase.' };

    const hash = await this.sha256Hex(value);

    try {
      const res = await fetch('/api/unlock', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ passphrase: value }),
        credentials: 'same-origin'
      });
      if (res.ok) {
        const data = await res.json();
        localStorage.setItem(this.LOCAL_KEY, hash);
        localStorage.setItem(this.SESSION_KEY, 'true');
        sessionStorage.setItem(this.SESSION_KEY, 'true');
        return { ok: true, created: Boolean(data?.created) };
      }
      if (res.status === 401 || res.status === 400) {
        const data = await res.json().catch(() => ({}));
        return { ok: false, error: data.error || 'Incorrect passphrase.' };
      }
    } catch {
      // Backend API not reachable; fall back to local storage unlock
    }

    const storedHash = localStorage.getItem(this.LOCAL_KEY);

    if (!storedHash) {
      localStorage.setItem(this.LOCAL_KEY, hash);
      localStorage.setItem(this.SESSION_KEY, 'true');
      sessionStorage.setItem(this.SESSION_KEY, 'true');
      return { ok: true, created: true };
    }

    if (storedHash === hash) {
      localStorage.setItem(this.SESSION_KEY, 'true');
      sessionStorage.setItem(this.SESSION_KEY, 'true');
      return { ok: true, created: false };
    }

    return { ok: false, error: 'Incorrect passphrase.' };
  },

  async setPassphrase(passphrase) {
    const value = (passphrase || '').trim();
    if (!value) return { ok: false, error: 'Passphrase cannot be empty.' };

    const hash = await this.sha256Hex(value);

    try {
      const res = await fetch('/api/passphrase', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ passphrase: value }),
        credentials: 'same-origin'
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        if (data.error) return { ok: false, error: data.error };
      }
    } catch {
      // Backend API not reachable; proceed with local storage setPassphrase
    }

    localStorage.setItem(this.LOCAL_KEY, hash);
    localStorage.setItem(this.SESSION_KEY, 'true');
    sessionStorage.setItem(this.SESSION_KEY, 'true');
    return { ok: true };
  },

  async lock() {
    try {
      await fetch('/api/lock', { method: 'POST', credentials: 'same-origin' });
    } catch {
      // Ignore API lock failure
    }
    localStorage.removeItem(this.SESSION_KEY);
    sessionStorage.removeItem(this.SESSION_KEY);
  }
};

window.Auth = Auth;
