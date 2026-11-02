enum { RECENT_LIMIT = 30, RECENT_HEADER = 8, RECENT_ROW = 16 };
typedef struct { char *target; char *path; } RecentFile;

static bool recent_json_string(Bytes *output, const char *text) {
    if (!append(output, "\"", 1, MAX_TEXT)) return false;
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p < 32 || *p == '"' || *p == '\\') {
            char escaped[7];
            snprintf(escaped, sizeof(escaped), "\\u%04x", *p);
            if (!append(output, escaped, 6, MAX_TEXT)) return false;
        } else if (!append(output, p, 1, MAX_TEXT)) return false;
    }
    return append(output, "\"", 1, MAX_TEXT);
}

static BinaryReply recent_files_operation(uint32_t operation, const char *target, const char *path) {
    BinaryReply reply = {0};
    RecentFile records[RECENT_LIMIT + 1] = {0};
    size_t count = 0;
    Bytes saved = {0}, encoded = {0};
    int lock = -1;
    char *base = draft_path("", "", "recent-files");
    char *filename = base ? format("%s.recents", base) : NULL;
    free(base);
    if (!filename) goto done;
    if (operation != CLIENT_RECENTS && (!*target || path[0] != '/')) {
        fail("Recent files require a target and an absolute path"); goto done;
    }
    lock = lock_draft(filename);
    if (lock < 0) goto done;
    errno = 0;
    saved = read_file(filename, MAX_TEXT, true);
    if (!saved.data) {
        if (errno != ENOENT) goto done;
        failure[0] = 0;
    } else {
        if (saved.size < DRAFT_HEADER || get_u32(saved.data) != 0x5244454f ||
            get_u32(saved.data + 4) != 1 || get_u32(saved.data + 8) != saved.size) {
            fail("Invalid recent files storage"); goto done;
        }
        size_t offset = get_u32(saved.data + 24), size = get_u32(saved.data + 28);
        if (offset < DRAFT_HEADER || offset > saved.size || size != saved.size - offset || size < RECENT_HEADER) {
            fail("Invalid recent files storage"); goto done;
        }
        Bytes list = {saved.data + offset, size};
        uint32_t stored_count = get_u32(list.data + 4);
        if (get_u32(list.data) != 1 || stored_count > RECENT_LIMIT || list.size < RECENT_HEADER + stored_count * RECENT_ROW) {
            fail("Invalid recent files storage"); goto done;
        }
        for (uint32_t i = 0; i < stored_count; i++) {
            RecentFile *record = &records[count++];
            size_t row = RECENT_HEADER + i * RECENT_ROW, variable = RECENT_HEADER + stored_count * RECENT_ROW;
            record->target = binary_read_string(list, row, variable, 4096);
            record->path = binary_read_string(list, row + 8, variable, PATH_MAX - 1);
            if (!record->target || !record->path) goto done;
            if (!utf8((unsigned char *)record->target, strlen(record->target)) ||
                !utf8((unsigned char *)record->path, strlen(record->path))) {
                fail("Invalid recent files text"); goto done;
            }
        }
    }
    if (operation != CLIENT_RECENTS) {
        for (size_t i = 0; i < count; i++) {
            if (!strcmp(records[i].target, target) && !strcmp(records[i].path, path)) {
                free(records[i].target); free(records[i].path);
                memmove(records + i, records + i + 1, (count - i - 1) * sizeof(*records));
                count--; break;
            }
        }
        if (operation == CLIENT_REMEMBER_RECENT) {
            memmove(records + 1, records, count * sizeof(*records));
            records[0] = (RecentFile){strdup(target), strdup(path)};
            count++;
            if (count > RECENT_LIMIT) { count--; free(records[count].target); free(records[count].path); }
        }
        encoded = (Bytes){allocate(RECENT_HEADER + count * RECENT_ROW), RECENT_HEADER + count * RECENT_ROW};
        put_u32(encoded.data, 1); put_u32(encoded.data + 4, (uint32_t)count);
        for (size_t i = 0; i < count; i++) {
            if (!binary_string(&encoded, RECENT_HEADER + i * RECENT_ROW, records[i].target) ||
                !binary_string(&encoded, RECENT_HEADER + i * RECENT_ROW + 8, records[i].path)) goto done;
        }
        if (!write_draft(filename, "recents", encoded)) goto done;
    }
    reply = response_create(OP_READ, 0, 0);
    binary_string(&reply.metadata, 48, ""); binary_string(&reply.metadata, 56, "");
    append(&reply.body, "[", 1, MAX_TEXT);
    for (size_t i = 0; i < count && !failure[0]; i++) {
        if (i) append(&reply.body, ",", 1, MAX_TEXT);
        append(&reply.body, "{\"target\":", 10, MAX_TEXT);
        recent_json_string(&reply.body, records[i].target);
        append(&reply.body, ",\"path\":", 8, MAX_TEXT);
        recent_json_string(&reply.body, records[i].path);
        append(&reply.body, "}", 1, MAX_TEXT);
    }
    append(&reply.body, "]", 1, MAX_TEXT);
done:
    for (size_t i = 0; i < count; i++) { free(records[i].target); free(records[i].path); }
    bytes_free(&saved); bytes_free(&encoded);
    if (lock >= 0) close(lock);
    free(filename);
    return reply;
}
