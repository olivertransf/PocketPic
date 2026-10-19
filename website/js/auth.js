//
// Auth module for PocketPic Web
// Handles passphrase setup, unlocking, verification, and session management.
//

const Auth = {
  PASSPHRASE_KEY: 'pocketpic_passphrase_hash',
  SESSION_UNLOCKED_KEY: 'pocketpic_session_unlocked',

  async hashPassphrase(passphrase) {
    const msgBuffer = new TextEncoder().encode(passphrase);
    const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  },

  isPassphraseSet() {
    return !!localStorage.getItem(this.PASSPHRASE_KEY);
  },

  isUnlocked() {
    if (!this.isPassphraseSet()) {
      return true; // No passphrase required if none set yet
    }
    return sessionStorage.getItem(this.SESSION_UNLOCKED_KEY) === 'true';
  },

  async setPassphrase(passphrase) {
    if (!passphrase || passphrase.trim().length === 0) {
      localStorage.removeItem(this.PASSPHRASE_KEY);
      sessionStorage.removeItem(this.SESSION_UNLOCKED_KEY);
      return true;
    }
    const hash = await this.hashPassphrase(passphrase.trim());
    localStorage.setItem(this.PASSPHRASE_KEY, hash);
    sessionStorage.setItem(this.SESSION_UNLOCKED_KEY, 'true');
    return true;
  },

  async unlock(passphrase) {
    if (!this.isPassphraseSet()) {
      sessionStorage.setItem(this.SESSION_UNLOCKED_KEY, 'true');
      return true;
    }
    const hash = await this.hashPassphrase(passphrase.trim());
    const storedHash = localStorage.getItem(this.PASSPHRASE_KEY);
    if (hash === storedHash) {
      sessionStorage.setItem(this.SESSION_UNLOCKED_KEY, 'true');
      return true;
    }
    return false;
  },

  lock() {
    sessionStorage.removeItem(this.SESSION_UNLOCKED_KEY);
  },

  clearPassphrase() {
    localStorage.removeItem(this.PASSPHRASE_KEY);
    sessionStorage.removeItem(this.SESSION_UNLOCKED_KEY);
  }
};

window.Auth = Auth;
