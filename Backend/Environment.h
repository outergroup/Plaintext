#ifndef APP_ENVIRONMENT_H
#define APP_ENVIRONMENT_H
#include <stddef.h>
char *environment_request(const void *body, size_t length, size_t *result_length);
// Finds this app's container helpers in the helpers folder beside web_root.
void environment_set_web_root(const char *web_root);
typedef struct EnvironmentWatch EnvironmentWatch;
EnvironmentWatch *environment_watch_open(const void *body, size_t length);
int environment_watch_ready(const EnvironmentWatch *watch);
int environment_watch_descriptor(const EnvironmentWatch *watch, int source);
int environment_watch_read(EnvironmentWatch *watch, int source);
void environment_watch_close(EnvironmentWatch *watch);
#endif
