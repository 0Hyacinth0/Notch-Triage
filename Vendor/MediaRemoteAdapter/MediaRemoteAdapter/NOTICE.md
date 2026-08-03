# MediaRemote Adapter

Notch Triage bundles `MediaRemoteAdapter` to read the system Now Playing
session on macOS versions where direct MediaRemote access is restricted.

- Upstream: <https://github.com/ungive/mediaremote-adapter>
- Source revision: `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`
- License: BSD 3-Clause (`MediaRemoteAdapter-LICENSE.txt`)
- Architectures: `arm64`, `x86_64`

The framework is embedded but not linked into Notch Triage. It is loaded by
the system `/usr/bin/perl` process through the upstream adapter script.
