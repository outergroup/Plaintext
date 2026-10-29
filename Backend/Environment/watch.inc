struct EnvironmentWatch {
    FileWatch local, draft;
    Child child;
    bool remote;
};

void environment_watch_close(EnvironmentWatch *watch) {
    if (!watch) return;
    file_watch_close(&watch->draft);
    if (watch->remote) child_close(&watch->child);
    else file_watch_close(&watch->local);
    free(watch);
}

int environment_watch_ready(const EnvironmentWatch *watch) { return !watch->remote; }

int environment_watch_descriptor(const EnvironmentWatch *watch, int source) {
    if (source == 2) return watch->draft.descriptor;
    return watch->remote ? watch->child.output : watch->local.descriptor;
}

int environment_watch_read(EnvironmentWatch *watch, int source) {
    if (source == 2) return file_watch_read(&watch->draft);
    if (!watch->remote) return file_watch_read(&watch->local);
    char events[256];
    ssize_t count = read(watch->child.output, events, sizeof(events));
    if (count < 0) return errno == EAGAIN || errno == EINTR ? 0 : -1;
    if (!count) return -1;
    for (ssize_t i = 0; i < count; i++) if (events[i] != 'R' && events[i] != 'C') return -1;
    return 1;
}

EnvironmentWatch *environment_watch_open(const void *body, size_t length) {
    Bytes input = {(unsigned char *)body, length};
    if (length < CLIENT_HEADER || length > MAX_DATA || get_u32(input.data) != 0x51434c50 ||
        get_u32(input.data + 4) != 1 || get_u32(input.data + 8) != length ||
        get_u32(input.data + 12) != CLIENT_DISK || get_u64(input.data + 16) || get_u32(input.data + 68)) return NULL;
    failure[0] = 0; deadline = now() + 10;
    char *target = binary_read_string(input, 24, CLIENT_HEADER, 4096);
    char *user = binary_read_string(input, 32, CLIENT_HEADER, 256);
    char *path = binary_read_string(input, 40, CLIENT_HEADER, PATH_MAX - 1);
    EnvironmentWatch *watch = NULL;
    if (!target || !user || !path || !*path || !utf8((unsigned char *)path, strlen(path)) ||
        (*user && !valid_identifier(user, 128, true))) goto done;
    watch = calloc(1, sizeof(*watch));
    if (!watch) goto done;
    watch->local.descriptor = watch->local.directory = watch->local.file = -1;
    watch->draft.descriptor = watch->draft.directory = watch->draft.file = -1;
    char *saved_draft = draft_path(target, user, path);
    bool watching_draft = saved_draft && file_watch_open(&watch->draft, saved_draft) == 0;
    free(saved_draft);
    if (!watching_draft) { environment_watch_close(watch); watch = NULL; goto done; }
    if (!strcmp(target, "host")) {
        if (file_watch_open(&watch->local, path)) { environment_watch_close(watch); watch = NULL; }
        goto done;
    }
    const char *colon = strchr(target, ':');
    if (!colon || !valid_identifier(colon + 1, 256, false)) { environment_watch_close(watch); watch = NULL; goto done; }
    EnvironmentSnapshot snapshot = discover_environments();
    bool started = false;
    for (size_t i = 1; i < snapshot.target_count; i++) {
        const EnvironmentTarget *entry = &snapshot.targets[i];
        if (strcmp(entry->id, target) || strcmp(entry->state, "running")) continue;
        char *args[18];
        size_t count = app_runtime_exec(app_runtime(entry->runtime), entry->executable, entry->socket,
                                       user, entry->container, HELPER_PATH, args, 18);
        if (!count) break;
        args[count - 1] = "watch"; args[count++] = path; args[count] = NULL;
        char **command_args = args;
#ifdef __APPLE__
        char *owner_args[32], owner_id[32], owner_user[32];
        if (geteuid() == 0 && entry->owner_uid != 0 && app_runtime(entry->runtime) == APP_RUNTIME_APPLE) {
            snprintf(owner_id, sizeof(owner_id), "%u", (unsigned)entry->owner_uid);
            snprintf(owner_user, sizeof(owner_user), "#%u", (unsigned)entry->owner_uid);
            char *prefix[] = {"/bin/launchctl", "asuser", owner_id, "/usr/bin/sudo", "-n", "-H", "-u", owner_user, "--"};
            size_t n = sizeof(prefix) / sizeof(*prefix);
            memcpy(owner_args, prefix, sizeof(prefix));
            for (size_t j = 0; args[j]; j++) owner_args[n++] = args[j];
            owner_args[n] = NULL; command_args = owner_args;
        }
#endif
        watch->remote = true;
        started = spawn(command_args, &watch->child);
        break;
    }
    environment_snapshot_free(&snapshot);
    if (!started) { environment_watch_close(watch); watch = NULL; }
done:
    free(target); free(user); free(path);
    return watch;
}
