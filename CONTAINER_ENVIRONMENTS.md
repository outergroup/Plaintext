# Plaintext container support

Plaintext owns `outer-plaintext-helper` in [Helper](Helper/README.md). The backend handles host operations directly and reuses long-running container helpers over stdin/stdout. Outer Shell supplies container discovery and installation, not an application-operation proxy.

Container images must install `/usr/local/bin/outer-plaintext-helper`. The bundled base images include each app's separate executable. Custom images can COPY the app's static helper directly. Release, deployment and development scripts build it from this app's Helper directory. The container process exits when its backend connection closes; it is not a separately managed daemon.

The HTML frontend uses the container-aware APIs. Outerframe behavior is unchanged. Docker is tested; Apple container/wslc still require live validation. Native Windows backend integration remains separate.


On macOS, discovery refreshes the user’s launchd registry socket after Outer Shell restarts. Root Plaintext discovers user registries and validates the owner’s local Docker socket; the system daemon is not queried as a default container provider. Explicit registry overrides remain supported. Use `./app deploy --local` for the Mac user app, or `OUTER_TARGET_SCOPE=system ./app deploy --local` for root.
