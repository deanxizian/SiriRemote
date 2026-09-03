# Local packages

Build and verify every component, then create both packages:

```sh
dist/build-release.sh 0.1.0
```

Artifacts are written to `dist/out/`:

- `SiriRemote-Full-Setup.pkg`
- `SiriRemote-Complete-Uninstall.pkg`
- `SHA256SUMS.txt`

The setup package installs only:

- `/Applications/SiriRemote.app`
- `/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver`
- `/Library/Application Support/SiriRemote/`
- `/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist`

The uninstall package removes those components plus SiriRemote user configuration, preferences and
logs for the current console user. It restores the exact pre-install `HCITraces` value and never
deletes PacketLogger, SiriRemoteForge, remote-mic-app, `MiRemoteV 2ch` or other audio devices.

The App, Capture service, router and HAL are code-signed. The PKG itself is intentionally unsigned
until a Developer ID Installer certificate is available, so this is a local package rather than a
notarized public release.

PacketLogger is not included in either package. At runtime the root Capture service copies the
user-installed Apple bundle into the protected SiriRemote support directory, validates its Apple
signature and fixed identifiers, strips inherited ACLs and executes only that root-owned snapshot.
The uninstaller removes the snapshot with the rest of the SiriRemote support directory.
