# Local packages

Build and verify every component, then create both packages:

```sh
dist/build-release.sh 0.2.1
```

Artifacts are written to `dist/out/`:

- `SiriRemote-<version>-Full-Setup.pkg`
- `SiriRemote-<version>-Complete-Uninstall.pkg`
- `SiriRemote-<version>-SHA256SUMS.txt`

To repeat the package-content and signature audit without rebuilding, pass the same version:

```sh
dist/audit-package.sh 0.2.1
```

The setup package installs only:

- `/Applications/SiriRemote.app`
- `/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver`
- `/Library/Application Support/SiriRemote/`
- `/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist`

The uninstall package removes those components plus SiriRemote user configuration, preferences and
logs for the current console user. It restores the exact pre-install `HCITraces` value and never
deletes PacketLogger, SiriRemoteForge, remote-mic-app, `MiRemoteV 2ch` or other audio devices.

The App, Capture service, router and HAL are signed with the stable Developer ID Application
identity. Both PKGs are signed with the matching Developer ID Installer identity and trusted
timestamps. They must still be verified against the accompanying SHA-256 file. A package is not
described as notarized until Apple accepts it and the notarization ticket has been stapled.

PacketLogger is not included in either package. At runtime the root Capture service copies the
user-installed Apple bundle into the protected SiriRemote support directory, validates its Apple
signature and fixed identifiers, strips inherited ACLs and executes only that root-owned snapshot.
The service compares the signed identity of both the outer App and its command-line component and
atomically refreshes the snapshot after a valid Apple PacketLogger update.
The uninstaller removes the snapshot with the rest of the SiriRemote support directory.

After installation or rollback, the package uses a signed native verifier to confirm that exactly
one UI process is running with the console user's UID and the kernel-reported executable path
`/Applications/SiriRemote.app/Contents/MacOS/SiriRemote`.

Upgrade rollback data is stored in a random, root-owned `0700` directory below
`/private/var/run/com.deanxi.siriremote-installer/`. Before a rollback is activated, the installer
revalidates the App, HAL, Capture service and router signatures, checks the LaunchDaemon's fixed
label and executable path, and rejects writable or symlinked privileged components.
