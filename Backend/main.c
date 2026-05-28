#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
extern int launch_activate_socket(const char *name, int **fds, size_t *cnt);
#endif

#define READ_CHUNK_SIZE 65536
#define MAX_HEADER_SIZE 65536
#define MAX_CLIENTS 256
#define CLIENT_TIMEOUT_SECONDS 5

static const char *kBundleUrlPath = "/bundles/PlaintextContent-v6";
static const char *kBundleUrlPathMacosArm = "/bundles/PlaintextContent-v6/macos-arm";
static const char *kBundleUrlPathMacosX86 = "/bundles/PlaintextContent-v6/macos-x86";
static const char *kBundleFilePathMacosArm = "bundles/PlaintextContent.bundle.macos-arm.aar";
static const char *kBundleFilePathMacosX86 = "bundles/PlaintextContent.bundle.macos-x86.aar";

static char g_bundle_file_path_macos_arm[PATH_MAX] = "";
static char g_bundle_file_path_macos_x86[PATH_MAX] = "";
static char g_backend_label[256] = "dev.outergroup.Plaintext";
static char g_listen_socket_path[PATH_MAX] = "";
static int g_listen_port = -1;
static bool g_systemd_socket_activation = false;
static bool g_listen_socket_is_launchd_owned = false;
static volatile sig_atomic_t g_shutdown_requested = 0;
static char g_drafts_directory[PATH_MAX] = "";

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} Buffer;

typedef struct {
    int fd;
    Buffer request;
    bool header_complete;
    size_t header_length;
    size_t content_length;
    time_t last_activity;
} Client;

static int ensure_directory_exists(const char *path);

static void handle_shutdown_signal(int signal_number) {
    (void)signal_number;
    g_shutdown_requested = 1;
}

static void fatal(const char *what) {
    perror(what);
    exit(EXIT_FAILURE);
}

static bool buffer_reserve(Buffer *buffer, size_t needed) {
    if (needed <= buffer->capacity) return true;
    size_t next = buffer->capacity == 0 ? 4096 : buffer->capacity;
    while (next < needed) {
        if (next > SIZE_MAX / 2) {
            next = needed;
            break;
        }
        next *= 2;
    }
    char *data = realloc(buffer->data, next);
    if (!data) return false;
    buffer->data = data;
    buffer->capacity = next;
    return true;
}

static bool buffer_append(Buffer *buffer, const void *data, size_t length) {
    if (length == 0) return true;
    if (!buffer_reserve(buffer, buffer->length + length + 1)) return false;
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return true;
}

static void buffer_free(Buffer *buffer) {
    free(buffer->data);
    buffer->data = NULL;
    buffer->length = 0;
    buffer->capacity = 0;
}

static bool write_all(int fd, const void *data, size_t length) {
    const char *bytes = (const char *)data;
    while (length > 0) {
        ssize_t written = write(fd, bytes, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        bytes += written;
        length -= (size_t)written;
    }
    return true;
}

static void send_response(int fd, int status, const char *status_text, const char *content_type, const void *body, size_t body_length) {
    char header[512];
    int header_length = snprintf(header, sizeof(header),
                                 "HTTP/1.1 %d %s\r\n"
                                 "Content-Type: %s\r\n"
                                 "Content-Length: %zu\r\n"
                                 "Connection: close\r\n"
                                 "Cache-Control: no-store\r\n"
                                 "\r\n",
                                 status, status_text, content_type, body_length);
    if (header_length > 0 && (size_t)header_length < sizeof(header)) {
        write_all(fd, header, (size_t)header_length);
    }
    if (body && body_length > 0) {
        write_all(fd, body, body_length);
    }
}

static void set_client_timeouts(int fd) {
    struct timeval timeout;
    timeout.tv_sec = 5;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static void send_text_response(int fd, int status, const char *text) {
    const char *status_text = status == 200 ? "OK" :
                              status == 400 ? "Bad Request" :
                              status == 404 ? "Not Found" :
                              status == 413 ? "Payload Too Large" :
                              status == 500 ? "Internal Server Error" : "Error";
    send_response(fd, status, status_text, "text/plain; charset=utf-8", text, strlen(text));
}

static void url_decode(const char *input, size_t input_length, char *out, size_t out_size) {
    if (!out || out_size == 0) return;
    size_t write_index = 0;
    for (size_t i = 0; input && i < input_length && write_index + 1 < out_size; ) {
        char c = input[i];
        if (c == '+') {
            out[write_index++] = ' ';
            i++;
        } else if (c == '%' && i + 2 < input_length &&
                   isxdigit((unsigned char)input[i + 1]) &&
                   isxdigit((unsigned char)input[i + 2])) {
            char hex[3] = {input[i + 1], input[i + 2], '\0'};
            out[write_index++] = (char)strtol(hex, NULL, 16);
            i += 3;
        } else {
            out[write_index++] = c;
            i++;
        }
    }
    out[write_index] = '\0';
}

static bool copy_query_value(const char *query, const char *key, char *out, size_t out_size) {
    if (!query || !key || !out || out_size == 0) return false;
    size_t key_length = strlen(key);
    const char *cursor = query;
    while (*cursor) {
        const char *amp = strchr(cursor, '&');
        size_t segment_length = amp ? (size_t)(amp - cursor) : strlen(cursor);
        if (segment_length > key_length + 1 &&
            strncmp(cursor, key, key_length) == 0 &&
            cursor[key_length] == '=') {
            url_decode(cursor + key_length + 1, segment_length - key_length - 1, out, out_size);
            return true;
        }
        if (!amp) break;
        cursor = amp + 1;
    }
    return false;
}

static bool query_value_is_true(const char *query, const char *key) {
    char value[32] = "";
    if (!copy_query_value(query, key, value, sizeof(value))) return false;
    return strcmp(value, "1") == 0 ||
           strcasecmp(value, "true") == 0 ||
           strcasecmp(value, "yes") == 0;
}

static uint64_t fnv1a64(const char *text) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (const unsigned char *cursor = (const unsigned char *)text; cursor && *cursor; cursor++) {
        hash ^= (uint64_t)*cursor;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static const char *home_directory(void) {
    const char *home = getenv("HOME");
    if (home && home[0] != '\0') return home;
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && pw->pw_dir[0] != '\0') return pw->pw_dir;
    return "/tmp";
}

static void default_drafts_directory(char *out, size_t out_size) {
    const char *state_home = getenv("XDG_STATE_HOME");
    if (state_home && state_home[0] != '\0') {
        snprintf(out, out_size, "%s/outerwebapps/plaintext-drafts", state_home);
        return;
    }
    snprintf(out, out_size, "%s/.local/state/outerwebapps/plaintext-drafts", home_directory());
}

static bool draft_path_for_file(const char *path, char *out, size_t out_size) {
    if (!path || path[0] == '\0') return false;
    if (g_drafts_directory[0] == '\0') {
        default_drafts_directory(g_drafts_directory, sizeof(g_drafts_directory));
    }
    if (ensure_directory_exists(g_drafts_directory) != 0) {
        return false;
    }
    int written = snprintf(out, out_size, "%s/%016llx.draft",
                           g_drafts_directory,
                           (unsigned long long)fnv1a64(path));
    if (written < 0 || (size_t)written >= out_size) {
        out[0] = '\0';
        return false;
    }
    return true;
}

static bool read_file_alloc(const char *path, char **out_contents, size_t *out_size, struct stat *out_stat) {
    *out_contents = NULL;
    *out_size = 0;
    int file_fd = open(path, O_RDONLY);
    if (file_fd < 0) return false;
    struct stat st;
    if (fstat(file_fd, &st) != 0) {
        close(file_fd);
        return false;
    }
    size_t size = st.st_size > 0 ? (size_t)st.st_size : 0;
    char *contents = malloc(size == 0 ? 1 : size);
    if (!contents) {
        close(file_fd);
        return false;
    }
    size_t total = 0;
    while (total < size) {
        ssize_t n = read(file_fd, contents + total, size - total);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        total += (size_t)n;
    }
    close(file_fd);
    if (total != size) {
        free(contents);
        errno = EIO;
        return false;
    }
    *out_contents = contents;
    *out_size = size;
    if (out_stat) *out_stat = st;
    return true;
}

static void write_uint32_le(unsigned char *bytes, uint32_t value) {
    bytes[0] = (unsigned char)(value & 0xff);
    bytes[1] = (unsigned char)((value >> 8) & 0xff);
    bytes[2] = (unsigned char)((value >> 16) & 0xff);
    bytes[3] = (unsigned char)((value >> 24) & 0xff);
}

static void write_uint64_le(unsigned char *bytes, uint64_t value) {
    for (int i = 0; i < 8; i++) {
        bytes[i] = (unsigned char)((value >> (i * 8)) & 0xff);
    }
}

static void write_double_le(unsigned char *bytes, double value) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    write_uint64_le(bytes, bits);
}

static void send_outer_descriptor(int fd) {
    const char *file_api_path = "/api/file";
    size_t plugin_header_length = 20;
    size_t file_api_path_length = strlen(file_api_path);
    size_t plugin_length = plugin_header_length + file_api_path_length;
    size_t path_length = strlen(kBundleUrlPath);
    size_t header_length = 40;
    size_t data_offset = header_length + path_length;
    size_t total_length = data_offset + plugin_length;
    unsigned char *payload = malloc(total_length);
    if (!payload) {
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    payload[0] = 'O';
    payload[1] = 'U';
    payload[2] = 'T';
    payload[3] = 'R';
    write_uint32_le(payload + 4, 1);
    write_uint64_le(payload + 8, (uint64_t)header_length);
    write_uint64_le(payload + 16, (uint64_t)path_length);
    write_uint64_le(payload + 24, (uint64_t)data_offset);
    write_uint64_le(payload + 32, (uint64_t)plugin_length);
    memcpy(payload + header_length, kBundleUrlPath, path_length);
    write_uint32_le(payload + data_offset, 1);
    write_uint64_le(payload + data_offset + 4, (uint64_t)plugin_header_length);
    write_uint64_le(payload + data_offset + 12, (uint64_t)file_api_path_length);
    memcpy(payload + data_offset + plugin_header_length, file_api_path, file_api_path_length);
    send_response(fd, 200, "OK", "application/vnd.outerframe", payload, total_length);
    free(payload);
}

static void send_outer_descriptor_head(int fd) {
    const char *file_api_path = "/api/file";
    size_t plugin_length = 20 + strlen(file_api_path);
    size_t path_length = strlen(kBundleUrlPath);
    size_t header_length = 40;
    size_t data_offset = header_length + path_length;
    size_t total_length = data_offset + plugin_length;
    send_response(fd, 200, "OK", "application/vnd.outerframe", NULL, total_length);
}

static void send_bundle_file(int fd, const char *path) {
    int file_fd = open(path, O_RDONLY);
    if (file_fd < 0) {
        send_text_response(fd, 404, "bundle not found\n");
        return;
    }
    struct stat st;
    if (fstat(file_fd, &st) != 0) {
        close(file_fd);
        send_text_response(fd, 500, "failed to stat bundle\n");
        return;
    }
    if (st.st_size < 0) {
        close(file_fd);
        send_text_response(fd, 500, "invalid bundle size\n");
        return;
    }
    size_t size = (size_t)st.st_size;
    char *data = malloc(size == 0 ? 1 : size);
    if (!data) {
        close(file_fd);
        send_text_response(fd, 500, "out of memory\n");
        return;
    }
    size_t total = 0;
    while (total < size) {
        ssize_t n = read(file_fd, data + total, size - total);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        total += (size_t)n;
    }
    close(file_fd);
    if (total != size) {
        free(data);
        send_text_response(fd, 500, "failed to read bundle\n");
        return;
    }
    send_response(fd, 200, "OK", "application/octet-stream", data, size);
    free(data);
}

static void write_ref64(unsigned char *bytes, uint64_t offset, uint64_t length) {
    write_uint64_le(bytes, offset);
    write_uint64_le(bytes + 8, length);
}

static void send_file_load_binary(int fd,
                                  bool ok,
                                  bool dirty,
                                  const char *path,
                                  const char *contents,
                                  size_t size,
                                  double modified,
                                  const char *error) {
    size_t header_length = 72;
    size_t path_length = path ? strlen(path) : 0;
    size_t error_length = error ? strlen(error) : 0;
    size_t contents_length = ok && contents ? size : 0;
    size_t contents_offset = header_length + path_length;
    size_t error_offset = contents_offset + contents_length;
    size_t total_length = error_offset + error_length;
    unsigned char *payload = calloc(1, total_length == 0 ? 1 : total_length);
    if (!payload) {
        send_text_response(fd, 500, "out of memory\n");
        return;
    }

    write_uint32_le(payload, 1);
    payload[4] = (ok ? 1 : 0) | (dirty ? 2 : 0);
    write_uint64_le(payload + 8, (uint64_t)size);
    write_double_le(payload + 16, modified);
    write_ref64(payload + 24, (uint64_t)header_length, (uint64_t)path_length);
    write_ref64(payload + 40, (uint64_t)contents_offset, (uint64_t)contents_length);
    write_ref64(payload + 56, (uint64_t)error_offset, (uint64_t)error_length);
    if (path_length > 0) memcpy(payload + header_length, path, path_length);
    if (contents_length > 0) memcpy(payload + contents_offset, contents, contents_length);
    if (error_length > 0) memcpy(payload + error_offset, error, error_length);

    send_response(fd, 200, "OK", "application/octet-stream", payload, total_length);
    free(payload);
}

static void send_file_save_binary(int fd,
                                  bool ok,
                                  bool dirty,
                                  const char *path,
                                  size_t size,
                                  double modified,
                                  const char *error) {
    size_t header_length = 56;
    size_t path_length = path ? strlen(path) : 0;
    size_t error_length = error ? strlen(error) : 0;
    size_t error_offset = header_length + path_length;
    size_t total_length = error_offset + error_length;
    unsigned char *payload = calloc(1, total_length == 0 ? 1 : total_length);
    if (!payload) {
        send_text_response(fd, 500, "out of memory\n");
        return;
    }

    write_uint32_le(payload, 1);
    payload[4] = (ok ? 1 : 0) | (dirty ? 2 : 0);
    write_uint64_le(payload + 8, (uint64_t)size);
    write_double_le(payload + 16, modified);
    write_ref64(payload + 24, (uint64_t)header_length, (uint64_t)path_length);
    write_ref64(payload + 40, (uint64_t)error_offset, (uint64_t)error_length);
    if (path_length > 0) memcpy(payload + header_length, path, path_length);
    if (error_length > 0) memcpy(payload + error_offset, error, error_length);

    send_response(fd, 200, "OK", "application/octet-stream", payload, total_length);
    free(payload);
}

static void send_file_get_response(int fd, const char *query) {
    char path[PATH_MAX] = "";
    if (!copy_query_value(query, "file", path, sizeof(path)) || path[0] == '\0') {
        send_file_load_binary(fd, false, false, "", NULL, 0, 0, "missing file query parameter");
        return;
    }

    char draft_path[PATH_MAX] = "";
    if (draft_path_for_file(path, draft_path, sizeof(draft_path))) {
        char *draft_contents = NULL;
        size_t draft_size = 0;
        struct stat draft_st;
        if (read_file_alloc(draft_path, &draft_contents, &draft_size, &draft_st)) {
            send_file_load_binary(fd, true, true, path, draft_contents, draft_size, (double)draft_st.st_mtime, "");
            free(draft_contents);
            return;
        }
    }

    char *contents = NULL;
    size_t size = 0;
    struct stat st;
    if (!read_file_alloc(path, &contents, &size, &st)) {
        send_file_load_binary(fd, false, false, path, NULL, 0, 0, strerror(errno));
        return;
    }

    send_file_load_binary(fd, true, false, path, contents, size, (double)st.st_mtime, "");
    free(contents);
}

static void send_file_save_response(int fd, const char *query, const char *body, size_t body_length) {
    char path[PATH_MAX] = "";
    if (!copy_query_value(query, "file", path, sizeof(path)) || path[0] == '\0') {
        send_file_save_binary(fd, false, false, "", 0, 0, "missing file query parameter");
        return;
    }

    char draft_path[PATH_MAX] = "";
    if (!draft_path_for_file(path, draft_path, sizeof(draft_path))) {
        send_file_save_binary(fd, false, false, path, 0, 0, "failed to create drafts directory");
        return;
    }

    if (query_value_is_true(query, "draft")) {
        int draft_fd = open(draft_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (draft_fd < 0) {
            send_file_save_binary(fd, false, false, path, 0, 0, strerror(errno));
            return;
        }
        bool wrote = write_all(draft_fd, body, body_length);
        int write_errno = errno;
        fsync(draft_fd);
        struct stat draft_st;
        if (fstat(draft_fd, &draft_st) != 0) {
            memset(&draft_st, 0, sizeof(draft_st));
        }
        close(draft_fd);
        if (!wrote) {
            send_file_save_binary(fd, false, false, path, 0, 0, strerror(write_errno));
            return;
        }

        send_file_save_binary(fd, true, true, path, (size_t)draft_st.st_size, (double)draft_st.st_mtime, "");
        return;
    }

    int file_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (file_fd < 0) {
        send_file_save_binary(fd, false, false, path, 0, 0, strerror(errno));
        return;
    }
    if (!write_all(file_fd, body, body_length)) {
        int saved_errno = errno;
        close(file_fd);
        send_file_save_binary(fd, false, false, path, 0, 0, strerror(saved_errno));
        return;
    }
    fsync(file_fd);
    struct stat st;
    if (fstat(file_fd, &st) != 0) {
        memset(&st, 0, sizeof(st));
    }
    close(file_fd);
    unlink(draft_path);

    send_file_save_binary(fd, true, false, path, (size_t)st.st_size, (double)st.st_mtime, "");
}

static char *find_header_end(char *data, size_t length) {
    for (size_t i = 0; i + 3 < length; i++) {
        if (data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n') {
            return data + i;
        }
    }
    return NULL;
}

static size_t content_length_from_headers(const char *headers) {
    const char *cursor = headers;
    while ((cursor = strcasestr(cursor, "Content-Length:")) != NULL) {
        cursor += strlen("Content-Length:");
        while (*cursor == ' ' || *cursor == '\t') cursor++;
        return (size_t)strtoull(cursor, NULL, 10);
    }
    return 0;
}

static void process_client_request(int fd, Buffer *request, size_t header_length, size_t content_length) {
    char *header_end = request->data + header_length - 4;
    *header_end = '\0';
    char method[16] = "";
    char target[2048] = "";
    char version[16] = "";
    if (sscanf(request->data, "%15s %2047s %15s", method, target, version) != 3) {
        send_text_response(fd, 400, "bad request\n");
        return;
    }

    char *query = strchr(target, '?');
    if (query) {
        *query = '\0';
        query++;
    } else {
        query = "";
    }

    bool is_get = strcasecmp(method, "GET") == 0;
    bool is_head = strcasecmp(method, "HEAD") == 0;
    if ((is_get || is_head) && (strcmp(target, "/") == 0 || strcmp(target, "/index") == 0)) {
        if (is_head) {
            send_outer_descriptor_head(fd);
        } else {
            send_outer_descriptor(fd);
        }
    } else if (strcasecmp(method, "GET") == 0 && strcmp(target, kBundleUrlPath) == 0) {
        send_text_response(fd, 200, "macos-arm\nmacos-x86\n");
    } else if (strcasecmp(method, "GET") == 0 && strcmp(target, kBundleUrlPathMacosArm) == 0) {
        send_bundle_file(fd, g_bundle_file_path_macos_arm[0] ? g_bundle_file_path_macos_arm : kBundleFilePathMacosArm);
    } else if (strcasecmp(method, "GET") == 0 && strcmp(target, kBundleUrlPathMacosX86) == 0) {
        send_bundle_file(fd, g_bundle_file_path_macos_x86[0] ? g_bundle_file_path_macos_x86 : kBundleFilePathMacosX86);
    } else if (strcasecmp(method, "GET") == 0 && strcmp(target, "/api/file") == 0) {
        send_file_get_response(fd, query);
    } else if (strcasecmp(method, "POST") == 0 && strcmp(target, "/api/file") == 0) {
        const char *body = request->data + header_length;
        size_t body_length = request->length >= header_length ? request->length - header_length : 0;
        if (body_length > content_length) body_length = content_length;
        send_file_save_response(fd, query, body, body_length);
    } else {
        send_text_response(fd, 404, "not found\n");
    }
}

static int set_fd_nonblocking(int fd, bool nonblocking) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (nonblocking) {
        flags |= O_NONBLOCK;
    } else {
        flags &= ~O_NONBLOCK;
    }
    return fcntl(fd, F_SETFL, flags);
}

static void client_init(Client *client) {
    memset(client, 0, sizeof(*client));
    client->fd = -1;
}

static void client_close(Client *client) {
    if (client->fd >= 0) {
        close(client->fd);
    }
    buffer_free(&client->request);
    client_init(client);
}

static bool client_parse_header(Client *client) {
    if (client->header_complete) return true;
    char *header_end = find_header_end(client->request.data, client->request.length);
    if (!header_end) {
        if (client->request.length > MAX_HEADER_SIZE) {
            send_text_response(client->fd, 413, "headers too large\n");
            return false;
        }
        return true;
    }

    client->header_length = (size_t)(header_end - client->request.data) + 4;
    char saved = *header_end;
    *header_end = '\0';
    client->content_length = content_length_from_headers(client->request.data);
    *header_end = saved;
    client->header_complete = true;
    return true;
}

static bool client_request_complete(const Client *client) {
    return client->header_complete &&
           client->request.length >= client->header_length + client->content_length;
}

static void handle_client_read(Client *client) {
    char chunk[READ_CHUNK_SIZE];
    while (true) {
        ssize_t n = read(client->fd, chunk, sizeof(chunk));
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            client_close(client);
            return;
        }
        if (n == 0) {
            client_close(client);
            return;
        }

        client->last_activity = time(NULL);
        if (!buffer_append(&client->request, chunk, (size_t)n)) {
            set_fd_nonblocking(client->fd, false);
            send_text_response(client->fd, 500, "out of memory\n");
            client_close(client);
            return;
        }
        if (!client_parse_header(client)) {
            client_close(client);
            return;
        }
        if (client_request_complete(client)) {
            set_fd_nonblocking(client->fd, false);
            process_client_request(client->fd,
                                   &client->request,
                                   client->header_length,
                                   client->content_length);
            client_close(client);
            return;
        }
    }
}

static int add_client(Client *clients, int fd) {
    for (size_t i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].fd >= 0) continue;
        client_init(&clients[i]);
        clients[i].fd = fd;
        clients[i].last_activity = time(NULL);
        set_client_timeouts(fd);
        if (set_fd_nonblocking(fd, true) != 0) {
            client_close(&clients[i]);
            return -1;
        }
        return 0;
    }
    return -1;
}

static void accept_ready_clients(int listen_fd, Client *clients) {
    while (true) {
        int client_fd = accept(listen_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            perror("accept");
            return;
        }
        if (add_client(clients, client_fd) != 0) {
            send_text_response(client_fd, 503, "too many clients\n");
            close(client_fd);
        }
    }
}

static void close_idle_clients(Client *clients) {
    time_t now = time(NULL);
    for (size_t i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].fd < 0) continue;
        if (now - clients[i].last_activity > CLIENT_TIMEOUT_SECONDS) {
            client_close(&clients[i]);
        }
    }
}

static void run_reactor(int listen_fd) {
    Client clients[MAX_CLIENTS];
    for (size_t i = 0; i < MAX_CLIENTS; i++) {
        client_init(&clients[i]);
    }
    if (set_fd_nonblocking(listen_fd, true) != 0) {
        fatal("fcntl");
    }

    while (!g_shutdown_requested) {
        struct pollfd fds[MAX_CLIENTS + 1];
        size_t client_indexes[MAX_CLIENTS];
        nfds_t count = 1;
        fds[0].fd = listen_fd;
        fds[0].events = POLLIN;
        fds[0].revents = 0;

        for (size_t i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i].fd < 0) continue;
            client_indexes[count - 1] = i;
            fds[count].fd = clients[i].fd;
            fds[count].events = POLLIN;
            fds[count].revents = 0;
            count++;
        }

        int ready = poll(fds, count, 1000);
        if (ready < 0) {
            if (errno == EINTR) continue;
            perror("poll");
            break;
        }

        if (ready > 0 && (fds[0].revents & POLLIN)) {
            accept_ready_clients(listen_fd, clients);
        }
        for (nfds_t i = 1; i < count; i++) {
            short revents = fds[i].revents;
            if (!revents) continue;
            size_t client_index = client_indexes[i - 1];
            if (revents & (POLLERR | POLLHUP | POLLNVAL)) {
                client_close(&clients[client_index]);
                continue;
            }
            if (revents & POLLIN) {
                handle_client_read(&clients[client_index]);
            }
        }
        close_idle_clients(clients);
    }

    for (size_t i = 0; i < MAX_CLIENTS; i++) {
        client_close(&clients[i]);
    }
}

static int ensure_directory_exists(const char *path) {
    if (!path || path[0] == '\0') return 0;
    char temp[PATH_MAX];
    snprintf(temp, sizeof(temp), "%s", path);
    size_t length = strlen(temp);
    for (size_t i = 1; i <= length; i++) {
        if (temp[i] != '/' && temp[i] != '\0') continue;
        char saved = temp[i];
        temp[i] = '\0';
        if (temp[0] != '\0' && mkdir(temp, 0700) != 0 && errno != EEXIST) {
            return -1;
        }
        temp[i] = saved;
    }
    return 0;
}

static int create_tcp_listener(int requested_port) {
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) fatal("socket");
    int opt = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)requested_port);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) fatal("bind");
    if (requested_port == 0) {
        socklen_t addr_len = sizeof(addr);
        if (getsockname(listen_fd, (struct sockaddr *)&addr, &addr_len) != 0) fatal("getsockname");
        g_listen_port = ntohs(addr.sin_port);
    } else {
        g_listen_port = requested_port;
    }
    if (listen(listen_fd, 64) != 0) fatal("listen");
    return listen_fd;
}

static void default_socket_path(char *out, size_t out_size) {
    const char *runtime_dir = getenv("XDG_RUNTIME_DIR");
    if (runtime_dir && runtime_dir[0] != '\0') {
        snprintf(out, out_size, "%s/%s", runtime_dir, g_backend_label);
        return;
    }
#ifdef __APPLE__
    const char *temp_dir = getenv("TMPDIR");
    if (temp_dir && temp_dir[0] != '\0') {
        snprintf(out, out_size, "%s%s", temp_dir, g_backend_label);
        return;
    }
#endif
    snprintf(out, out_size, "/tmp/%s", g_backend_label);
}

static int create_unix_listener(const char *requested_socket_path) {
    int listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd < 0) fatal("socket");
    if (requested_socket_path && requested_socket_path[0] != '\0') {
        snprintf(g_listen_socket_path, sizeof(g_listen_socket_path), "%s", requested_socket_path);
    } else {
        default_socket_path(g_listen_socket_path, sizeof(g_listen_socket_path));
    }
    char socket_dir[PATH_MAX];
    snprintf(socket_dir, sizeof(socket_dir), "%s", g_listen_socket_path);
    char *slash = strrchr(socket_dir, '/');
    if (!slash) fatal("socket path");
    *slash = '\0';
    if (ensure_directory_exists(socket_dir) != 0) fatal("mkdir");
    unlink(g_listen_socket_path);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(g_listen_socket_path) >= sizeof(addr.sun_path)) fatal("socket path too long");
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", g_listen_socket_path);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) fatal("bind");
    chmod(g_listen_socket_path, 0600);
    if (listen(listen_fd, 64) != 0) fatal("listen");
    return listen_fd;
}

static int systemd_activated_listener(void) {
    const char *listen_pid = getenv("LISTEN_PID");
    const char *listen_fds = getenv("LISTEN_FDS");
    if (!listen_pid || !listen_fds) {
        return -1;
    }

    char *end = NULL;
    long pid = strtol(listen_pid, &end, 10);
    if (!end || *end != '\0' || pid != (long)getpid()) {
        return -1;
    }

    end = NULL;
    long fds = strtol(listen_fds, &end, 10);
    if (!end || *end != '\0' || fds < 1) {
        return -1;
    }

    unsetenv("LISTEN_PID");
    unsetenv("LISTEN_FDS");
    unsetenv("LISTEN_FDNAMES");
    g_systemd_socket_activation = true;
    return 3;
}

#ifdef __APPLE__
static int create_launchd_unix_listener(const char *socket_name, const char *socket_path) {
    int *fds = NULL;
    size_t count = 0;
    int result = launch_activate_socket(socket_name, &fds, &count);
    if (result != 0) {
        errno = result;
        fatal("launch_activate_socket");
    }
    if (!fds || count == 0) fatal("launchd socket");
    int listen_fd = fds[0];
    for (size_t i = 1; i < count; i++) close(fds[i]);
    free(fds);
    if (socket_path && socket_path[0] != '\0') {
        snprintf(g_listen_socket_path, sizeof(g_listen_socket_path), "%s", socket_path);
    } else {
        default_socket_path(g_listen_socket_path, sizeof(g_listen_socket_path));
    }
    g_listen_socket_is_launchd_owned = true;
    return listen_fd;
}
#endif

static bool parse_port(const char *value, int *out) {
    if (!value || value[0] == '\0') return false;
    char *end = NULL;
    long port = strtol(value, &end, 10);
    if (!end || *end != '\0' || port < 0 || port > 65535) return false;
    *out = (int)port;
    return true;
}

static void print_usage(const char *program) {
    fprintf(stderr, "Usage: %s [--port PORT | --socket-path PATH] [--launchd-socket-name NAME] [--label LABEL] [--bundles-dir DIR]\n",
            program && program[0] ? program : "PlaintextBackend");
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_shutdown_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);

    int requested_port = -1;
    char requested_socket_path[PATH_MAX] = "";
#ifdef __APPLE__
    char launchd_socket_name[128] = "";
#endif

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--label") == 0 && i + 1 < argc) {
            snprintf(g_backend_label, sizeof(g_backend_label), "%s", argv[++i]);
        } else if (strcmp(argv[i], "--bundles-dir") == 0 && i + 1 < argc) {
            snprintf(g_bundle_file_path_macos_arm, sizeof(g_bundle_file_path_macos_arm),
                     "%s/PlaintextContent.bundle.macos-arm.aar", argv[i + 1]);
            snprintf(g_bundle_file_path_macos_x86, sizeof(g_bundle_file_path_macos_x86),
                     "%s/PlaintextContent.bundle.macos-x86.aar", argv[i + 1]);
            i++;
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            if (!parse_port(argv[++i], &requested_port)) {
                print_usage(argv[0]);
                return 2;
            }
            requested_socket_path[0] = '\0';
        } else if (strcmp(argv[i], "--socket-path") == 0 && i + 1 < argc) {
            snprintf(requested_socket_path, sizeof(requested_socket_path), "%s", argv[++i]);
            requested_port = -1;
#ifdef __APPLE__
        } else if (strcmp(argv[i], "--launchd-socket-name") == 0 && i + 1 < argc) {
            snprintf(launchd_socket_name, sizeof(launchd_socket_name), "%s", argv[++i]);
            requested_port = -1;
#endif
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            print_usage(argv[0]);
            return 2;
        }
    }

    int listen_fd;
    if (requested_port >= 0) {
        listen_fd = create_tcp_listener(requested_port);
    } else if ((listen_fd = systemd_activated_listener()) >= 0) {
        if (requested_socket_path[0] != '\0') {
            snprintf(g_listen_socket_path, sizeof(g_listen_socket_path), "%s", requested_socket_path);
        }
#ifdef __APPLE__
    } else if (launchd_socket_name[0] != '\0') {
        listen_fd = create_launchd_unix_listener(launchd_socket_name, requested_socket_path);
#endif
    } else {
        listen_fd = create_unix_listener(requested_socket_path);
    }

    if (g_listen_port >= 0) {
        printf("PlaintextBackend listening on http://127.0.0.1:%d/\n", g_listen_port);
    } else if (g_systemd_socket_activation && g_listen_socket_path[0] == '\0') {
        printf("PlaintextBackend listening on inherited systemd socket\n");
    } else {
        printf("PlaintextBackend listening on unix socket %s\n", g_listen_socket_path);
    }
    fflush(stdout);

    run_reactor(listen_fd);

    close(listen_fd);
    if (g_listen_socket_path[0] != '\0' && !g_systemd_socket_activation && !g_listen_socket_is_launchd_owned) {
        unlink(g_listen_socket_path);
    }
    return 0;
}
