#include "helper.h"
#include "watch.h"
int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc == 2 && !strcmp(argv[1], "--version")) { puts(HELPER_NAME " 1"); return 0; }
    if (argc == 2 && !strcmp(argv[1], "serve")) return serve();
    if (argc == 3 && !strcmp(argv[1], "watch")) return file_watch_serve(argv[2]);
    fputs("Usage: " HELPER_NAME " serve | watch PATH | --version\n", stderr);
    return 2;
}
