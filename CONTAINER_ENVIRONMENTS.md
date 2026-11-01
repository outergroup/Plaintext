# Plaintext container support

Plaintext owns `outer-plaintext-helper` in [Helper](Helper/README.md). The backend handles host operations directly and reuses long-running container helpers over stdin/stdout. Outer Shell supplies container discovery and installation, not an application-operation proxy.

The app ships its static helpers as `helpers/linux-x86_64/outer-plaintext-helper` and `helpers/linux-aarch64/outer-plaintext-helper` beside its `web` folder, and copies the helper into a container the first time it needs it, using Outer Shell's `ContainerHelper.h`; images Outer Shell builds with Docker include it already. Any container with `/bin/sh` works. Release, deployment and development scripts build the helpers from this app's Helper directory. The container process exits when its backend connection closes; it is not a separately managed daemon.

The HTML frontend uses the container-aware APIs. Outerframe behavior is unchanged. Docker is tested; Apple container/wslc still require live validation. Native Windows backend integration remains separate.


On macOS, discovery refreshes the user’s launchd registry socket after Outer Shell restarts. Root Plaintext discovers user registries and validates the owner’s local Docker socket; the system daemon is not queried as a default container provider. Explicit registry overrides remain supported. Use `./app deploy --local` for the Mac user app, or `OUTER_TARGET_SCOPE=system ./app deploy --local` for root.
