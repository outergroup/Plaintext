#include "helper.h"
static bool revision(const char *path, char out[65]) {
    errno = 0;
    Bytes b = read_file(path, MAX_TEXT, true);
    if (!b.data) {
        if (errno == ENOENT) {
            failure[0] = 0;
            strcpy(out, "missing");
            return true;
        }
        return false;
    }
    digest(b.data, b.size, out);
    bytes_free(&b);
    return true;
}
static bool check_revision(const char *path, const char *expected) {
    char actual[65];
    if (!*expected) {
        fail("open the file before saving or moving it");
        return false;
    }
    if (!revision(path, actual))
        return false;
    if (strcmp(actual, expected)) {
        fail("the file changed since it was opened; reopen it before saving");
        return false;
    }
    return true;
}
static void parent_path(const char *path, char out[PATH_MAX]) {
    snprintf(out, PATH_MAX, "%s", path);
    char *p = strrchr(out, '/');
    if (p == out)
        out[1] = 0;
    else if (p)
        *p = 0;
}
static bool save_destination(const char *path, char out[PATH_MAX]) {
    snprintf(out, PATH_MAX, "%s", path);
    for (int i = 0; i < 40; i++) {
        char parent[PATH_MAX], resolved[PATH_MAX], next[PATH_MAX];
        parent_path(out, parent);
        if (!realpath(parent, resolved)) {
            fail("resolve parent: %s", strerror(errno));
            return false;
        }
        const char *name = strrchr(out, '/');
        if (snprintf(next, sizeof(next), "%s/%s", resolved, name ? name + 1 : out) >= (int)sizeof(next)) {
            fail("path too long");
            return false;
        }
        struct stat st;
        if (lstat(next, &st)) {
            if (errno == ENOENT) {
                strcpy(out, next);
                return true;
            }
            fail("stat: %s", strerror(errno));
            return false;
        }
        if (!S_ISLNK(st.st_mode)) {
            strcpy(out, next);
            return true;
        }
        char link[PATH_MAX];
        ssize_t n = readlink(next, link, sizeof(link) - 1);
        if (n < 0) {
            fail("readlink: %s", strerror(errno));
            return false;
        }
        link[n] = 0;
        if (link[0] == '/')
            snprintf(out, PATH_MAX, "%s", link);
        else if (snprintf(out, PATH_MAX, "%s/%s", resolved, link) >= PATH_MAX) {
            fail("path too long");
            return false;
        }
    }
    fail("too many symbolic links");
    return false;
}
static bool save_file(const char *path, Bytes body, const char *expected) {
    if (body.size > MAX_TEXT) {
        fail("document exceeds the 4 MiB limit");
        return false;
    }
    char dest[PATH_MAX];
    if (!save_destination(path, dest) || !check_revision(dest, expected))
        return false;
    struct stat old;
    bool exists = stat(dest, &old) == 0;
    if (!exists && errno != ENOENT) {
        fail("stat: %s", strerror(errno));
        return false;
    }
    char parent[PATH_MAX];
    parent_path(dest, parent);
    char *temp = format("%s/.plaintext-XXXXXX", parent);
    int fd = mkstemp(temp);
    if (fd < 0) {
        fail("create temporary file: %s", strerror(errno));
        free(temp);
        return false;
    }
    bool ok = true;
    if (exists && (fchown(fd, old.st_uid, old.st_gid) || fchmod(fd, old.st_mode & 07777))) {
        fail("preserve ownership/permissions: %s", strerror(errno));
        ok = false;
    }
    if (ok)
        ok = write_all(fd, body.data, body.size);
    if (ok && fsync(fd)) {
        fail("fsync: %s", strerror(errno));
        ok = false;
    }
    if (close(fd) && ok) {
        fail("close: %s", strerror(errno));
        ok = false;
    }
    if (ok)
        ok = check_revision(dest, expected);
    if (ok && rename(temp, dest)) {
        fail("save: %s", strerror(errno));
        ok = false;
    }
    unlink(temp);
    free(temp);
    return ok;
}
typedef struct {
    char *name, *path;
    char mode[11];
    bool directory;
    uint32_t access;
    uint64_t size, modified;
} FileEntry;
static int compare_entries(const void *a, const void *b) {
    const FileEntry *x = a, *y = b;
    if (x->directory != y->directory)
        return x->directory ? -1 : 1;
    return strcasecmp(x->name, y->name);
}
static BinaryReply list_files(const char *path) {
    BinaryReply result = {0};
    DIR *dir = opendir(path);
    if (!dir) {
        fail("%s: %s", path, strerror(errno));
        return result;
    }
    FileEntry *rows = NULL;
    size_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        char *full = format("%s%s%s", path, !strcmp(path, "/") ? "" : "/", entry->d_name);
        struct stat st;
        if (stat(full, &st) && lstat(full, &st)) {
            free(full);
            continue;
        }
        if (count >= (MAX_DATA - RESPONSE_SIZE) / FILE_ROW_SIZE) {
            free(full);
            fail("too many directory entries");
            break;
        }
        FileEntry *next = realloc(rows, (count + 1) * sizeof(*rows));
        if (!next) {
            free(full);
            fail("out of memory");
            break;
        }
        rows = next;
        FileEntry *r = &rows[count++];
        *r = (FileEntry){.name = strdup(entry->d_name),
                         .path = full,
                         .directory = S_ISDIR(st.st_mode),
                         .size = (uint64_t)st.st_size,
                         .access = (access(full, R_OK) == 0 ? 1 : 0) | (access(full, W_OK) == 0 ? 2 : 0)};
#ifdef __APPLE__
        r->modified = (uint64_t)st.st_mtimespec.tv_sec * 1000 + (uint64_t)st.st_mtimespec.tv_nsec / 1000000;
#else
        r->modified = (uint64_t)st.st_mtim.tv_sec * 1000 + (uint64_t)st.st_mtim.tv_nsec / 1000000;
#endif
        strcpy(r->mode, "----------");
        if (S_ISDIR(st.st_mode))
            r->mode[0] = 'd';
        else if (S_ISLNK(st.st_mode))
            r->mode[0] = 'l';
        for (int i = 0; i < 9; i++)
            if (st.st_mode & (1 << (8 - i)))
                r->mode[i + 1] = "rwx"[i % 3];
    }
    closedir(dir);
    if (!failure[0]) {
        if (count > 1)
            qsort(rows, count, sizeof(*rows), compare_entries);
        result = response_create(OP_LIST, (uint32_t)count, FILE_ROW_SIZE);
        char parent[PATH_MAX];
        parent_path(path, parent);
        binary_string(&result.metadata, 48, path);
        binary_string(&result.metadata, 56, parent);
        for (size_t i = 0; i < count && !failure[0]; i++) {
            FileEntry *r = &rows[i];
            size_t offset = RESPONSE_SIZE + i * FILE_ROW_SIZE;
            binary_string(&result.metadata, offset, r->name);
            binary_string(&result.metadata, offset + 8, r->path);
            binary_string(&result.metadata, offset + 16, r->mode);
            put_u32(result.metadata.data + offset + 24, r->directory);
            put_u32(result.metadata.data + offset + 28, r->access);
            put_u64(result.metadata.data + offset + 32, r->size);
            put_u64(result.metadata.data + offset + 40, r->modified);
        }
    }
    for (size_t i = 0; i < count; i++) {
        free(rows[i].name);
        free(rows[i].path);
    }
    free(rows);
    return result;
}
static bool move_file(const char *path, const char *dest, const char *expected) {
    if (!check_revision(path, expected))
        return false;
    struct stat st;
    if (stat(path, &st) || !S_ISREG(st.st_mode)) {
        fail("only regular files can be moved");
        return false;
    }
    if (lstat(path, &st)) {
        fail("stat: %s", strerror(errno));
        return false;
    }
    int r;
    if (S_ISLNK(st.st_mode)) {
        char linktext[PATH_MAX];
        ssize_t n = readlink(path, linktext, sizeof(linktext) - 1);
        if (n < 0) {
            fail("readlink: %s", strerror(errno));
            return false;
        }
        linktext[n] = 0;
        r = symlink(linktext, dest);
    } else
        r = link(path, dest);
    if (r) {
        fail("move: %s", strerror(errno));
        return false;
    }
    if (unlink(path)) {
        fail("remove source: %s", strerror(errno));
        unlink(dest);
        return false;
    }
    return true;
}
BinaryReply local_binary_operation(const Request *request, Bytes body) {
    BinaryReply r = {0};
    uint32_t op = request->operation;
    if (op != OP_SAVE && body.size) {
        fail("unexpected request body");
        return r;
    }
    char path[PATH_MAX];
    if (!expand_path(request->path, path))
        return r;
    switch (op) {
    case OP_LIST:
        r = list_files(path);
        break;
    case OP_READ:
        if (!request->limit || request->limit > MAX_DATA) {
            fail("invalid file size limit");
            break;
        }
        r.body = read_file(path, (size_t)request->limit, true);
        if (r.body.data) {
            Bytes data = r.body;
            r = response_create(op, 0, 0);
            r.body = data;
            char rev[65];
            digest(data.data, data.size, rev);
            binary_string(&r.metadata, 48, path);
            binary_string(&r.metadata, 56, rev);
        }
        break;
    case OP_SAVE:
        if (save_file(path, body, request->revision)) {
            r = response_create(op, 0, 0);
            char rev[65];
            digest(body.data, body.size, rev);
            binary_string(&r.metadata, 48, path);
            binary_string(&r.metadata, 56, rev);
        }
        break;
    case OP_MOVE: {
        char dest[PATH_MAX];
        if (expand_path(request->destination, dest) && move_file(path, dest, request->revision)) {
            r = response_create(op, 0, 0);
            binary_string(&r.metadata, 48, dest);
        }
        break;
    }
    default:
        fail("unsupported helper operation");
        break;
    }
    return r;
}
