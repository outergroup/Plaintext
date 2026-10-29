#ifndef PLAINTEXT_FILE_WATCH_H
#define PLAINTEXT_FILE_WATCH_H
#include <stdbool.h>
#include <sys/stat.h>
#include <limits.h>
typedef struct {
    int descriptor, directory, file;
    char path[PATH_MAX], parent[PATH_MAX];
    struct stat previous;
    bool exists;
} FileWatch;
int file_watch_open(FileWatch *watch, const char *path);
int file_watch_read(FileWatch *watch);
void file_watch_close(FileWatch *watch);
int file_watch_serve(const char *path);
#endif
