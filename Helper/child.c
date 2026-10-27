#ifdef __linux__
#include <sys/syscall.h>
#endif
#include "helper.h"
static void close_fd(int *fd) {
    if (*fd >= 0)
        close(*fd);
    *fd = -1;
}
bool spawn(char *const *args, Child *child) {
    *child = (Child){.pid = -1, .input = -1, .output = -1, .error = -1};
    int in[2] = {-1, -1}, out[2] = {-1, -1};
    char temp[] = "/tmp/outer-plaintext-helper-stderr-XXXXXX";
    int error = mkstemp(temp);
    if (error >= 0) {
        unlink(temp);
        fcntl(error, F_SETFD, FD_CLOEXEC);
    }
    if (error < 0 || pipe(in) || pipe(out)) {
        fail("create process pipes: %s", strerror(errno));
        goto bad;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(in[i], F_SETFD, FD_CLOEXEC);
        fcntl(out[i], F_SETFD, FD_CLOEXEC);
    }
    long descriptor_limit = sysconf(_SC_OPEN_MAX);
    if (descriptor_limit < 0) descriptor_limit = 65536;
    pid_t pid = fork();
    if (pid < 0) {
        fail("fork: %s", strerror(errno));
        goto bad;
    }
    if (!pid) {
        setpgid(0, 0);
        dup2(in[0], 0);
        dup2(out[1], 1);
        dup2(error, 2);
        close(in[0]);
        close(in[1]);
        close(out[0]);
        close(out[1]);
        close(error);
#if defined(__linux__) && defined(SYS_close_range)
        if (syscall(SYS_close_range, 3u, ~0u, 0u) != 0)
#endif
            for (int fd = 3; fd < descriptor_limit; fd++) close(fd);
        execv(args[0], args);
        _exit(127);
    }
    setpgid(pid, pid);
    close(in[0]);
    close(out[1]);
    fcntl(in[1], F_SETFL, O_NONBLOCK);
    fcntl(out[0], F_SETFL, O_NONBLOCK);
    *child = (Child){pid, in[1], out[0], error};
    return true;
bad:
    for (int i = 0; i < 2; i++) {
        close_fd(&in[i]);
        close_fd(&out[i]);
    }
    if (error >= 0)
        close(error);
    return false;
}
void child_close(Child *c) {
    close_fd(&c->input);
    close_fd(&c->output);
    if (c->pid > 0) {
        for (int i = 0; i < 50; i++) {
            pid_t result = waitpid(c->pid, NULL, WNOHANG);
            if (result == c->pid || (result < 0 && errno == ECHILD)) { c->pid = -1; break; }
            struct timespec delay = {0, 10000000};
            nanosleep(&delay, NULL);
        }
        if (c->pid > 0) kill(-c->pid, SIGKILL);
        while (c->pid > 0 && waitpid(c->pid, NULL, 0) < 0 && errno == EINTR) {
        }
        c->pid = -1;
    }
    close_fd(&c->error);
}
Bytes command(char *const *args, double timeout) {
    Bytes b = {0};
    Child c;
    if (!spawn(args, &c))
        return b;
    close_fd(&c.input);
    double until = now() + timeout;
    if (deadline && until > deadline)
        until = deadline;
    bool ok = true;
    unsigned char block[8192];
    for (;;) {
        double remaining = until - now();
        if (remaining <= 0) {
            fail("container runtime timed out");
            ok = false;
            break;
        }
        struct pollfd p = {c.output, POLLIN, 0};
        int n = poll(&p, 1, (int)(remaining * 1000) + 1);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            fail("container runtime timed out");
            ok = false;
            break;
        }
        ssize_t got = read(c.output, block, sizeof(block));
        if (got < 0 && (errno == EAGAIN || errno == EINTR))
            continue;
        if (got < 0) {
            fail("runtime read: %s", strerror(errno));
            ok = false;
            break;
        }
        if (!got)
            break;
        if (!append(&b, block, (size_t)got, MAX_DATA)) {
            ok = false;
            break;
        }
    }
    if (ok) {
        int status = 0;
        for (;;) {
            pid_t r = waitpid(c.pid, &status, WNOHANG);
            if (r == c.pid) {
                c.pid = -1;
                if (!WIFEXITED(status) || WEXITSTATUS(status)) {
                    char err[4097] = {0};
                    lseek(c.error, 0, SEEK_SET);
                    ssize_t n = read(c.error, err, sizeof(err) - 1);
                    if (n < 0)
                        n = 0;
                    err[n] = 0;
                    fail("container runtime failed: %s", err);
                    ok = false;
                }
                break;
            }
            if (r < 0 && errno != EINTR) {
                fail("waitpid: %s", strerror(errno));
                ok = false;
                break;
            }
            if (now() >= until) {
                fail("container runtime timed out");
                ok = false;
                break;
            }
            struct timespec pause = {0, 1000000};
            nanosleep(&pause, NULL);
        }
    }
    child_close(&c);
    if (!ok)
        bytes_free(&b);
    else if (!b.data)
        append(&b, "", 0, MAX_DATA);
    return b;
}
