const PlaintextDrafts = (() => {
    'use strict';
    const fields = ['id','target','user','path','contents','revision','version','dirty','pendingSave','conflict','updatedAt','draftRevision','remoteVersion'];
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
                version:0,draftRevision:'missing',dirty:false,pendingSave:null,conflict:false,updatedAt:Date.now()}, record);
            this.store = store; this.api = api; this.changed = changed;
            this.schedule = schedule; this.cancel = cancel;
            this.localVersion = -1; this.remoteVersion = record.remoteVersion ?? (this.dirty ? -1 : this.version);
            this.writes = Promise.resolve(); this.localError = ''; this.networkError = '';
            this.retryDelay = 1000; this.stopped = false;
            this.watching = false; this.refreshEpoch = 0; this.refreshNeeded = false;
        }
        notify() { this.changed(this); }
        get message() {
            if (this.localError) return 'Not saved on this device: '+this.localError+'. Keep this page open or download a copy.';
            if (this.conflict) return 'Changes were made on another device. Review changes before continuing.';
            if (this.networkError) return (this.pendingSave?'Save queued. ':'')+this.networkError;
            return '';
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
            if (path !== this.path) { this.path = path; this.revision = 'missing'; this.draftRevision = 'missing'; this.remoteVersion = -1; }
            this.pendingSave = {id:crypto.randomUUID(),path:this.path,contents:this.contents,revision:this.revision,draftRevision:this.draftRevision,version:this.version};
            this.updatedAt = Date.now();
            if (!(await this.persist())) return false;
            this.resume();
            return true;
        }
        resume() {
            this.stopped = false; this.retryDelay = 1000;
            this.cancel(this.retryTimer); this.retryTimer = null;
            void this.sync();
            void this.refresh();
        }
        setWatching(watching) {
            if (this.watching !== watching) this.refreshEpoch++;
            this.watching = watching;
            if (!watching) this.refreshNeeded = false;
        }
        async refresh() {
            this.refreshNeeded = true;
            if (this.refreshRunning) return this.refreshRunning;
            if (!this.watching || this.stopped || !this.path || this.remoteVersion < this.version || this.pendingSave || this.conflict || this.composing) return;
            this.refreshNeeded = false;
            this.refreshRunning = this.readSharedState();
            try { await this.refreshRunning; }
            finally {
                this.refreshRunning = null;
                if (this.refreshNeeded && this.watching && !this.stopped && this.remoteVersion >= this.version && !this.pendingSave && !this.conflict && !this.composing) void this.refresh();
            }
        }
        async readSharedState() {
            const {version, path, revision, target, user, refreshEpoch} = this;
            try {
                const disk = await this.api('state', {path}, {target, user});
                if (!this.watching || this.stopped || this.refreshEpoch !== refreshEpoch ||
                    this.version !== version || this.path !== path || this.revision !== revision ||
                    this.target !== target || this.user !== user || this.remoteVersion < this.version || this.pendingSave ||
                    this.conflict || this.composing) return;
                if (disk.revision === revision && disk.draftRevision === this.draftRevision && disk.dirty === this.dirty && !!disk.draftConflict === this.conflict) return;
                this.contents = disk.contents; this.revision = disk.revision; this.draftRevision = disk.draftRevision;
                this.dirty = disk.dirty; this.conflict = !!disk.draftConflict;
                this.version++; this.remoteVersion = this.version; this.updatedAt = Date.now();
                this.notify();
                await this.persist();
            } catch {}
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
            if (this.path !== saved.path) return;
            this.path = result.path || saved.path;
            this.revision = result.revision;
            this.draftRevision = result.draftRevision;
            if (this.pendingSave?.id === saved.id) this.pendingSave = null;
            else if (this.pendingSave?.revision === saved.revision) {
                this.pendingSave.revision = result.revision;
                this.pendingSave.draftRevision = result.draftRevision;
            }
            if (this.version === saved.version) this.dirty = false;
            this.remoteVersion = saved.version;
            this.networkError = ''; this.retryDelay = 1000;
            await this.persist();
            if (this.refreshNeeded) void this.refresh();
        }
        async performSync() {
            if (!(await this.persist())) return;
            const saved = this.pendingSave && structuredClone(this.pendingSave);
            const version = this.version;
            try {
                if (saved) {
                    let result;
                    try { result = await this.api('commit', saved, this); }
                    catch (error) {
                        let disk;
                        try { disk = await this.api('disk', {path:saved.path}, this); }
                        catch { throw error; }
                        if (disk.contents === saved.contents) { result = {...disk, draftRevision:'missing'}; this.refreshNeeded = true; }
                        else if (disk.revision !== saved.revision) {
                            this.conflict = true; this.networkError = ''; await this.persist(); return;
                        } else throw error;
                    }
                    await this.acknowledge(saved, result);
                } else if (this.dirty && this.remoteVersion < version) {
                    const published = {path:this.path, contents:this.contents, revision:this.revision, draftRevision:this.draftRevision};
                    let result;
                    try { result = await this.api('publish', published, this); }
                    catch (error) {
                        if (!error.network && !error.conflict) throw error;
                        let current;
                        try { current = await this.api('state', {path:published.path}, this); }
                        catch { throw error; }
                        if (current.contents === published.contents && current.revision === published.revision && !current.draftConflict) result = current;
                        else if (current.draftRevision !== published.draftRevision) throw Object.assign(Error('The shared draft changed on another device.'), {conflict:true});
                        else throw error;
                    }
                    if (this.path === published.path) {
                        this.draftRevision = result.draftRevision;
                        this.remoteVersion = version;
                    }
                    if (this.pendingSave?.path === published.path && this.pendingSave.draftRevision === published.draftRevision) this.pendingSave.draftRevision = result.draftRevision;
                    this.networkError = ''; this.retryDelay = 1000;
                    await this.persist();
                    if (this.refreshNeeded) void this.refresh();
                }
            } catch (error) {
                if (error.conflict) {
                    this.conflict = true; this.networkError = ''; await this.persist(); return;
                }
                this.networkError = error.network ? 'Waiting for connection.' : error.message;
                if (error.network) {
                    this.retryTimer = this.schedule(() => { this.retryTimer = null; void this.sync(); }, this.retryDelay);
                    this.retryDelay = Math.min(this.retryDelay * 2, 30000);
                } else this.stopped = true;
            }
            this.notify();
        }
        async resolveConflict(revision, draftRevision) {
            this.revision = revision; this.draftRevision = draftRevision; this.conflict = false; this.pendingSave = null;
            return this.requestSave();
        }
        async saveCopy(path) {
            if (!path || path === this.path) return false;
            this.conflict = false; this.pendingSave = null;
            return this.requestSave(path);
        }
        stop() {
            this.stopped = true; this.refreshEpoch++; this.refreshNeeded = false;
            for (const timer of [this.localTimer,this.syncTimer,this.retryTimer]) this.cancel(timer);
            this.localTimer = this.syncTimer = this.retryTimer = null;
        }
    }
    class Notifications {
        constructor({open, changed, schedule = (fn, delay) => setTimeout(fn, delay), cancel = timer => clearTimeout(timer)}) {
            this.open = open; this.changed = changed; this.schedule = schedule; this.cancel = cancel;
            this.delay = 1000; this.stopped = false;
        }
        async connect() {
            if (this.stopped || this.controller) return;
            const controller = new AbortController(); this.controller = controller;
            let reader;
            try {
                const response = await this.open(controller.signal);
                if (!response.ok || !response.body) throw Error('File notification connection unavailable');
                reader = response.body.getReader();
                const decoder = new TextDecoder(); let pending = '';
                while (!this.stopped) {
                    const {value, done} = await reader.read();
                    if (done) break;
                    pending += decoder.decode(value, {stream:true});
                    let end;
                    while ((end = pending.indexOf('\n')) >= 0) {
                        const line = pending.slice(0, end); pending = pending.slice(end + 1);
                        if (line && JSON.parse(line).changed === true && !this.stopped) this.changed();
                        this.delay = 1000;
                    }
                    if (pending.length > 1024) throw Error('Invalid file notification');
                }
            } catch {} finally {
                try { await reader?.cancel(); } catch {}
                controller.abort(); this.controller = null;
                if (!this.stopped) {
                    this.timer = this.schedule(() => { this.timer = null; void this.connect(); }, this.delay);
                    this.delay = Math.min(this.delay * 2, 30000);
                }
            }
        }
        stop() {
            this.stopped = true; this.cancel(this.timer); this.timer = null;
            this.controller?.abort();
        }
    }
    return {Store, Document, Notifications, snapshot};
})();
if (typeof module !== 'undefined') module.exports = PlaintextDrafts;
