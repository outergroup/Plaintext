const PlaintextDrafts = (() => {
    'use strict';
    const fields = ['id','target','user','path','contents','revision','version','dirty','pendingSave','conflict','updatedAt'];
    function snapshot(doc) {
        return structuredClone(Object.fromEntries(fields.map(key => [key, doc[key]])));
    }
    class Store {
        constructor() { this.database = null; }
        open() {
            if (!this.database) this.database = new Promise((resolve, reject) => {
                const request = indexedDB.open('plaintext-drafts', 1);
                request.onupgradeneeded = () => request.result.createObjectStore('drafts', {keyPath:'id'});
                request.onerror = () => reject(request.error);
                request.onblocked = () => reject(Error('Draft storage is blocked by another window'));
                request.onsuccess = () => {
                    const db = request.result;
                    db.onversionchange = () => { db.close(); this.database = null; };
                    resolve(db);
                };
            }).catch(error => { this.database = null; throw error; });
            return this.database;
        }
        async transaction(mode, operation) {
            const db = await this.open();
            return new Promise((resolve, reject) => {
                const tx = db.transaction('drafts', mode);
                const request = operation(tx.objectStore('drafts'));
                tx.oncomplete = () => resolve(request.result);
                tx.onabort = () => reject(tx.error || request.error || Error('Draft storage transaction failed'));
                tx.onerror = () => {};
            });
        }
        put(value) { return this.transaction('readwrite', store => store.put(value)); }
        get(id) { return this.transaction('readonly', store => store.get(id)); }
        all() { return this.transaction('readonly', store => store.getAll()); }
    }
    class Document {
        constructor(record, {store, api, changed = () => {}, schedule = (fn, delay) => setTimeout(fn, delay), cancel = timer => clearTimeout(timer)}) {
            Object.assign(this, {id:crypto.randomUUID(),target:'host',user:'',path:'',contents:'',revision:'missing',
                version:0,dirty:false,pendingSave:null,conflict:false,updatedAt:Date.now()}, record);
            this.store = store; this.api = api; this.changed = changed;
            this.schedule = schedule; this.cancel = cancel;
            this.localVersion = -1; this.remoteVersion = -1;
            this.writes = Promise.resolve(); this.localError = ''; this.networkError = '';
            this.retryDelay = 1000; this.stopped = false;
        }
        notify() { this.changed(this); }
        get message() {
            if (this.localError) return 'Not saved on this device: '+this.localError+'. Keep this page open or download a copy.';
            if (this.localVersion < this.version) return 'Saving draft on this device…';
            if (this.conflict) return 'Saved on this device · File changed elsewhere. Review changes before saving.';
            if (this.networkError) return 'Saved on this device · '+(this.pendingSave?'Save queued. ':'')+this.networkError;
            if (this.pendingSave) return 'Saved on this device · Saving file…';
            if (!this.dirty) return this.path?'Saved to file':'Saved on this device';
            return this.remoteVersion === this.version?'Draft saved on this device and server':'Draft saved on this device';
        }
        edit(contents) {
            this.contents = contents; this.version++; this.dirty = true; this.updatedAt = Date.now();
            if (!this.localTimer) this.localTimer = this.schedule(() => { this.localTimer = null; void this.persist(); }, 100);
            this.cancel(this.syncTimer);
            this.syncTimer = this.schedule(() => { this.syncTimer = null; void this.sync(); }, 700);
            this.notify();
        }
        persist() {
            this.cancel(this.localTimer); this.localTimer = null;
            const value = snapshot(this);
            const write = this.writes.then(() => this.store.put(value));
            this.writes = write.catch(() => {});
            return write.then(() => {
                this.localVersion = Math.max(this.localVersion, value.version); this.localError = ''; this.notify(); return true;
            }, error => { this.localError = error.message || String(error); this.notify(); return false; });
        }
        async requestSave(path = this.path) {
            if (!path || this.conflict) return false;
            if (path !== this.path) { this.path = path; this.revision = 'missing'; this.remoteVersion = -1; }
            this.pendingSave = {id:crypto.randomUUID(),path:this.path,contents:this.contents,revision:this.revision,version:this.version};
            this.updatedAt = Date.now();
            if (!(await this.persist())) return false;
            this.resume();
            return true;
        }
        resume() {
            this.stopped = false; this.retryDelay = 1000;
            this.cancel(this.retryTimer); this.retryTimer = null;
            void this.sync();
        }
        async sync() {
            if (this.running) return this.running;
            if (this.stopped || this.conflict || !this.path) return;
            this.cancel(this.syncTimer); this.syncTimer = null;
            this.running = this.performSync();
            try { await this.running; }
            finally {
                this.running = null;
                if (!this.stopped && !this.conflict && !this.retryTimer &&
                    (this.pendingSave || (this.dirty && this.remoteVersion < this.version))) {
                    this.syncTimer = this.schedule(() => { this.syncTimer = null; void this.sync(); }, 700);
                }
            }
        }
        async acknowledge(saved, result) {
            this.path = result.path || saved.path;
            this.revision = result.revision;
            if (this.pendingSave?.id === saved.id) this.pendingSave = null;
            else if (this.pendingSave?.revision === saved.revision) this.pendingSave.revision = result.revision;
            if (this.version === saved.version) this.dirty = false;
            this.remoteVersion = saved.version;
            this.networkError = ''; this.retryDelay = 1000;
            await this.persist();
        }
        async performSync() {
            if (!(await this.persist())) return;
            const saved = this.pendingSave && structuredClone(this.pendingSave);
            const version = this.version;
            try {
                if (saved) {
                    let result;
                    try { result = await this.api('save', saved, this); }
                    catch (error) {
                        let disk;
                        try { disk = await this.api('disk', {path:saved.path}, this); }
                        catch { throw error; }
                        if (disk.contents === saved.contents) result = disk;
                        else if (disk.revision !== saved.revision) {
                            this.conflict = true; this.networkError = ''; await this.persist(); return;
                        } else throw error;
                    }
                    await this.acknowledge(saved, result);
                } else if (this.dirty && this.remoteVersion < version) {
                    await this.api('draft', {path:this.path,contents:this.contents,revision:this.revision}, this);
                    this.remoteVersion = version; this.networkError = ''; this.retryDelay = 1000;
                }
            } catch (error) {
                this.networkError = error.network ? 'Waiting for connection.' : error.message;
                if (error.network) {
                    this.retryTimer = this.schedule(() => { this.retryTimer = null; void this.sync(); }, this.retryDelay);
                    this.retryDelay = Math.min(this.retryDelay * 2, 30000);
                } else this.stopped = true;
            }
            this.notify();
        }
        async resolveConflict(revision) {
            this.revision = revision; this.conflict = false; this.pendingSave = null;
            return this.requestSave();
        }
        async saveCopy(path) {
            if (!path || path === this.path) return false;
            this.conflict = false; this.pendingSave = null;
            return this.requestSave(path);
        }
        stop() {
            this.stopped = true;
            for (const timer of [this.localTimer,this.syncTimer,this.retryTimer]) this.cancel(timer);
            this.localTimer = this.syncTimer = this.retryTimer = null;
        }
    }
    return {Store, Document, snapshot};
})();
if (typeof module !== 'undefined') module.exports = PlaintextDrafts;
