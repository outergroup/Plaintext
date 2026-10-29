#include "helper.h"
#include "watch.h"
#ifdef __APPLE__
#include <sys/event.h>
#else
#include <sys/inotify.h>
#endif

static bool watch_stat_equal(const struct stat *a, const struct stat *b) {
#ifdef __APPLE__
    bool times = a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
                 a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
#else
    bool times = a->st_mtim.tv_sec == b->st_mtim.tv_sec && a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
                 a->st_ctim.tv_sec == b->st_ctim.tv_sec && a->st_ctim.tv_nsec == b->st_ctim.tv_nsec;
#endif
    return times && a->st_ino == b->st_ino && a->st_dev == b->st_dev && a->st_size == b->st_size && a->st_mode == b->st_mode;
}

static int watch_attach(FileWatch *watch, const char *path, bool directory) {
#ifdef __APPLE__
    int fd = open(path, O_EVTONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    struct kevent event;
    EV_SET(&event, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE, 0, NULL);
    if (kevent(watch->descriptor, &event, 1, NULL, 0, NULL) < 0) { close(fd); return -1; }
    (void)directory;
    return fd;
#else
    return inotify_add_watch(watch->descriptor, path, directory
        ? IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF | IN_CLOSE_WRITE
        : IN_MODIFY | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF | IN_CLOSE_WRITE);
#endif
}

static void watch_detach(FileWatch *watch, int fd) {
    if (fd < 0) return;
#ifdef __APPLE__
    (void)watch;
    close(fd);
#else
    inotify_rm_watch(watch->descriptor, fd);
#endif
}

void file_watch_close(FileWatch *watch) {
    watch_detach(watch, watch->file);
    watch_detach(watch, watch->directory);
    if (watch->descriptor >= 0) close(watch->descriptor);
    watch->descriptor = watch->directory = watch->file = -1;
}

int file_watch_open(FileWatch *watch, const char *path) {
    memset(watch, 0, sizeof(*watch));
    watch->descriptor = watch->directory = watch->file = -1;
    if (!expand_path(path, watch->path)) return -1;
    snprintf(watch->parent, sizeof(watch->parent), "%s", watch->path);
    char *slash = strrchr(watch->parent, '/');
    if (!slash) return -1;
    if (slash == watch->parent) slash[1] = 0; else *slash = 0;
#ifdef __APPLE__
    watch->descriptor = kqueue();
    if (watch->descriptor >= 0) fcntl(watch->descriptor, F_SETFD, FD_CLOEXEC);
#else
    watch->descriptor = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
#endif
    if (watch->descriptor < 0) return -1;
    watch->directory = watch_attach(watch, watch->parent, true);
    if (watch->directory < 0) goto bad;
    struct stat before = {0};
    bool existed = stat(watch->path, &before) == 0;
    watch->file = watch_attach(watch, watch->path, false);
    watch->exists = stat(watch->path, &watch->previous) == 0;
    if (watch->exists && (!S_ISREG(watch->previous.st_mode) || watch->file < 0)) goto bad;
    if (!watch->exists && errno != ENOENT) goto bad;
    if (existed != watch->exists || (existed && (before.st_ino != watch->previous.st_ino || before.st_dev != watch->previous.st_dev))) goto bad;
    return 0;
bad:
    file_watch_close(watch);
    return -1;
}

int file_watch_read(FileWatch *watch) {
    bool parent_lost = false;
#ifdef __APPLE__
    struct kevent events[16];
    struct timespec timeout = {0};
    int count = kevent(watch->descriptor, NULL, 0, events, 16, &timeout);
    if (count < 0) return errno == EINTR ? 0 : -1;
    for (int i = 0; i < count; i++)
        if ((int)events[i].ident == watch->directory && (events[i].fflags & (NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE))) parent_lost = true;
#else
    char buffer[16384] __attribute__((aligned(__alignof__(struct inotify_event))));
    ssize_t count = read(watch->descriptor, buffer, sizeof(buffer));
    if (count < 0) return errno == EAGAIN || errno == EINTR ? 0 : -1;
    for (size_t offset = 0; offset < (size_t)count;) {
        struct inotify_event *event = (struct inotify_event *)(buffer + offset);
        if (event->wd == watch->directory && (event->mask & (IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED))) parent_lost = true;
        offset += sizeof(*event) + event->len;
    }
#endif
    if (parent_lost) return -1;
    struct stat current = {0};
    bool exists = stat(watch->path, &current) == 0;
    bool changed = exists != watch->exists || (exists && !watch_stat_equal(&current, &watch->previous));
    bool replaced = exists != watch->exists || (exists && (current.st_ino != watch->previous.st_ino || current.st_dev != watch->previous.st_dev));
    if (replaced) {
        watch_detach(watch, watch->file);
        watch->file = exists ? watch_attach(watch, watch->path, false) : -1;
        if (exists && watch->file < 0) return -1;
        struct stat attached;
        if (exists && (stat(watch->path, &attached) || attached.st_ino != current.st_ino || attached.st_dev != current.st_dev)) return -1;
    }
    watch->exists = exists; watch->previous = current;
    return changed ? 1 : 0;
}

int file_watch_serve(const char *path) {
    FileWatch watch;
    if (file_watch_open(&watch, path)) return 1;
    if (write(STDOUT_FILENO, "R", 1) != 1) { file_watch_close(&watch); return 1; }
    for (;;) {
        struct pollfd fds[] = {{watch.descriptor, POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) { if (errno == EINTR) continue; break; }
        if (fds[1].revents) break;
        if (fds[0].revents) {
            int result = file_watch_read(&watch);
            if (result < 0 || (result > 0 && write(STDOUT_FILENO, "C", 1) != 1)) break;
        }
    }
    file_watch_close(&watch);
    return 0;
}
