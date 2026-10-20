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
    const unlocked = sessionStorage.getItem(this.SESSION_KEY) === 'true';
    return { unlocked, passphraseSet: storedHash !== null };
  },

  async unlock(passphrase) {
    const value = (passphrase || '').trim();
    if (!value) return { ok: false, error: 'Enter a passphrase.' };

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

    const hash = await this.sha256Hex(value);
    localStorage.setItem(this.LOCAL_KEY, hash);
    sessionStorage.setItem(this.SESSION_KEY, 'true');
    return { ok: true };
  },

  async lock() {
    sessionStorage.removeItem(this.SESSION_KEY);
  }
};

window.Auth = Auth;
