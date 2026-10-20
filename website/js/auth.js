//
// Auth module for PocketPic Web
// The passphrase hash lives in the R2 bucket; the Worker checks it and sets an HttpOnly session cookie.
//

const Auth = {
  async status() {
    const response = await fetch('/api/session', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) throw new Error(`Server returned ${response.status}`);
    return response.json();
  },

  async unlock(passphrase) {
    return this.postPassphrase('/api/unlock', 'POST', passphrase);
  },

  async setPassphrase(passphrase) {
    return this.postPassphrase('/api/passphrase', 'PUT', passphrase);
  },

  async lock() {
    try {
      await fetch('/api/lock', { method: 'POST', credentials: 'same-origin' });
    } catch (e) {
      console.warn('Lock request failed:', e);
    }
  },

  async postPassphrase(path, method, passphrase) {
    const value = (passphrase || '').trim();
    if (!value) return { ok: false, error: 'Enter a passphrase.' };

    try {
      const response = await fetch(path, {
        method,
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ passphrase: value })
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) return { ok: false, error: body.error || `Server returned ${response.status}` };
      return { ok: true, created: !!body.created };
    } catch (e) {
      return { ok: false, error: 'Could not reach PocketPic. Check your connection.' };
    }
  }
};

window.Auth = Auth;
