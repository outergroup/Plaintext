#include "environment.h"
enum { CLIENT_HEADER = 72, CLIENT_RESPONSE = 48, DRAFT_HEADER = 32,
       CLIENT_TARGETS = 7, CLIENT_PREVIEW = 8, CLIENT_DRAFT = 9, CLIENT_DISK = 10 };
static char *draft_path(const char *target, const char *user, const char *path) {
    const char *state = getenv("XDG_STATE_HOME");
    char *root = NULL;
    if (state && *state) root = format("%s/outershell/plaintext-environments", state);
    else {
        const char *home = getenv("HOME");
        if (!home || !*home) {
            struct passwd *pw = getpwuid(geteuid());
            home = pw ? pw->pw_dir : NULL;
        }
        if (!home) { fail("cannot resolve draft directory"); return NULL; }
        root = format("%s/.local/state/outershell/plaintext-environments", home);
    }
    if (!mkdirs(root)) { free(root); return NULL; }
    Bytes key = {allocate(24), 24};
    bool ok = binary_string(&key, 0, target) && binary_string(&key, 8, user) &&
              binary_string(&key, 16, path);
    char hash[65];
    digest(key.data, key.size, hash);
    bytes_free(&key);
    char *result = ok ? format("%s/%s.oedraft", root, hash) : NULL;
    free(root);
    return result;
}
static bool write_draft(const char *path, const char *revision, Bytes body) {
    Bytes encoded = {allocate(DRAFT_HEADER), DRAFT_HEADER};
    put_u32(encoded.data, 0x5244454f);
    put_u32(encoded.data + 4, 1);
    bool ok = binary_string(&encoded, 16, revision);
    put_u32(encoded.data + 24, (uint32_t)encoded.size);
    put_u32(encoded.data + 28, (uint32_t)body.size);
    ok = ok && append(&encoded, body.data, body.size, MAX_DATA);
    put_u32(encoded.data + 8, (uint32_t)encoded.size);
    char *temp = format("%s.XXXXXX", path);
    int fd = ok ? mkstemp(temp) : -1;
    if (ok && fd < 0) { fail("create draft: %s", strerror(errno)); ok = false; }
    if (ok) ok = write_all(fd, encoded.data, encoded.size);
    if (ok && fsync(fd)) { fail("sync draft: %s", strerror(errno)); ok = false; }
    if (fd >= 0 && close(fd) && ok) { fail("close draft: %s", strerror(errno)); ok = false; }
    if (ok && rename(temp, path)) { fail("write draft: %s", strerror(errno)); ok = false; }
    unlink(temp);
    free(temp);
    bytes_free(&encoded);
    return ok;
}
static bool restore_draft(const char *path, BinaryReply *reply, uint32_t *flags) {
    errno = 0;
    Bytes saved = read_file(path, MAX_TEXT + 128, true);
    if (!saved.data) {
        if (errno == ENOENT) { failure[0] = 0; return true; }
        return false;
    }
    bool ok = saved.size >= DRAFT_HEADER && get_u32(saved.data) == 0x5244454f &&
              get_u32(saved.data + 4) == 1 && get_u32(saved.data + 8) == saved.size &&
              !get_u32(saved.data + 12);
    char *revision = NULL, *contents = NULL, *current = NULL;
    if (ok) {
        revision = binary_read_string(saved, 16, DRAFT_HEADER, 64);
        contents = binary_read_string(saved, 24, DRAFT_HEADER, MAX_TEXT);
        current = binary_read_string(reply->metadata, 56, get_u32(reply->metadata.data + 32), 64);
        ok = revision && contents && current && utf8((unsigned char *)contents, strlen(contents));
    }
    if (ok) {
        *flags = 1 | (strcmp(current, revision) ? 2 : 0);
        bytes_free(&reply->body);
        reply->body = (Bytes){(unsigned char *)contents, strlen(contents)};
        contents = NULL;
        ok = binary_string(&reply->metadata, 56, revision);
    } else if (!failure[0]) fail("invalid saved draft");
    free(revision); free(contents); free(current); bytes_free(&saved);
    return ok;
}
static Bytes client_response(BinaryReply reply, Bytes snapshot, uint32_t flags, const char *type) {
    char message[sizeof(failure)];
    snprintf(message, sizeof(message), "%s", failure);
    Bytes result = {allocate(CLIENT_RESPONSE), CLIENT_RESPONSE};
    put_u32(result.data, 0x52434c50);
    put_u32(result.data + 4, 1);
    put_u32(result.data + 12, message[0] ? 1 : 0);
    put_u32(result.data + 40, flags);
    failure[0] = 0;
    binary_string(&result, 32, message[0] ? message : type);
    Bytes metadata = snapshot.data ? snapshot : reply.metadata;
    if (message[0]) metadata = (Bytes){0};
    put_u32(result.data + 16, (uint32_t)result.size);
    put_u32(result.data + 20, (uint32_t)metadata.size);
    append(&result, metadata.data, metadata.size, MAX_DATA * 2);
    put_u32(result.data + 24, (uint32_t)result.size);
    put_u32(result.data + 28, message[0] ? 0 : (uint32_t)reply.body.size);
    if (!message[0]) append(&result, reply.body.data, reply.body.size, MAX_DATA * 2);
    put_u32(result.data + 8, (uint32_t)result.size);
    if (failure[0]) bytes_free(&result);
    return result;
}
Bytes dispatch_binary(Bytes input, const char *method) {
    Request request = {0};
    char *target = NULL, *user = NULL, *draft = NULL;
    BinaryReply reply = {0};
    Bytes snapshot = {0}, body = {0};
    uint32_t operation = 0, flags = 0;
    const char *type = "";
    if (failure[0]) goto done;
    if (strcmp(method, "POST")) { fail("environment requests require POST"); goto done; }
    if (input.size < CLIENT_HEADER || get_u32(input.data) != 0x51434c50 ||
        get_u32(input.data + 4) != 1 || get_u32(input.data + 8) != input.size ||
        get_u64(input.data + 16)) { fail("invalid environment request header"); goto done; }
    operation = get_u32(input.data + 12);
    bool allowed = operation == CLIENT_TARGETS || operation == OP_LIST || operation == OP_READ || operation == OP_SAVE || operation == OP_MOVE || operation == CLIENT_DRAFT || operation == CLIENT_DISK;
    if (!allowed) { fail("operation is not supported by this app"); goto done; }
    target = binary_read_string(input, 24, CLIENT_HEADER, 4096);
    user = binary_read_string(input, 32, CLIENT_HEADER, 256);
    request.path = binary_read_string(input, 40, CLIENT_HEADER, PATH_MAX - 1);
    request.destination = binary_read_string(input, 48, CLIENT_HEADER, PATH_MAX - 1);
    request.revision = binary_read_string(input, 56, CLIENT_HEADER, 64);
    request.start = strdup("");
    if (!target || !user || !request.path || !request.destination || !request.revision) goto done;
    char *fields[] = {target, user, request.path, request.destination, request.revision};
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++)
        if (!utf8((unsigned char *)fields[i], strlen(fields[i]))) { fail("invalid UTF-8 request"); goto done; }
    size_t offset = get_u32(input.data + 64), length = get_u32(input.data + 68);
    if (offset < CLIENT_HEADER || offset > input.size || length > input.size - offset || length > MAX_TEXT ||
        ((operation != OP_SAVE && operation != CLIENT_DRAFT) && length)) {
        fail("invalid request body"); goto done;
    }
    body = (Bytes){input.data + offset, length};
    if (!utf8(body.data, body.size)) { fail("document is not UTF-8 text"); goto done; }
    if (operation == CLIENT_TARGETS) {
        EnvironmentSnapshot environments = discover_environments();
        snapshot = environment_snapshot_encode(&environments);
        environment_snapshot_free(&environments);
        goto done;
    }
    request.operation = operation == CLIENT_PREVIEW || operation == CLIENT_DISK ? OP_READ : operation;
    request.limit = operation == CLIENT_PREVIEW ? MAX_DATA : MAX_TEXT;
    request.data_length = body.size;
    if (operation == CLIENT_DRAFT || operation == OP_SAVE || operation == OP_MOVE) {
        draft = draft_path(target, user, request.path);
        if (!draft) goto done;
    }
    if (operation == CLIENT_DRAFT) {
        if (write_draft(draft, request.revision, body)) reply = response_create(OP_SAVE, 0, 0);
        goto done;
    }
    reply = environment_binary_operation(target, user, &request, body);
    if (failure[0] || !response_validate(reply, request.operation)) goto done;
    if (operation == OP_READ || operation == CLIENT_DISK) {
        char hash[65];
        digest(reply.body.data, reply.body.size, hash);
        char *resolved = binary_read_string(reply.metadata, 48, get_u32(reply.metadata.data + 32), PATH_MAX - 1);
        char *revision = binary_read_string(reply.metadata, 56, get_u32(reply.metadata.data + 32), 64);
        if (!resolved || !*resolved || !revision || strcmp(hash, revision) || !utf8(reply.body.data, reply.body.size))
            fail("invalid UTF-8 file or helper read response");
        if (!failure[0]) draft = draft_path(target, user, resolved);
        free(resolved); free(revision);
        if (draft && operation != CLIENT_DISK) restore_draft(draft, &reply, &flags);
    } else if (operation == OP_SAVE) {
        if (unlink(draft) && errno != ENOENT) fail("file saved, but draft cleanup failed: %s", strerror(errno));
    } else if (operation == OP_MOVE) {
        char *dest = binary_read_string(reply.metadata, 48, get_u32(reply.metadata.data + 32), PATH_MAX - 1);
        char *new_path = dest && *dest ? draft_path(target, user, dest) : NULL;
        if (!new_path && !failure[0]) fail("invalid helper move response");
        if (new_path && rename(draft, new_path) && errno != ENOENT)
            fail("file moved, but draft migration failed: %s", strerror(errno));
        free(dest); free(new_path);
    }
done:
    response_finish(&reply);
    Bytes result = client_response(reply, snapshot, flags, type);
    free(target); free(user); free(draft); request_free(&request);
    binary_reply_free(&reply); bytes_free(&snapshot);
    return result;
}

Bytes environment_operation(Bytes input) { return dispatch_binary(input, "POST"); }
