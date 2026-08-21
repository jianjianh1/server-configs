# Google Drive with rclone

`install.sh` installs and updates `rclone`. Linux uses the official amd64 or
arm64 release under `~/.local/bin`; macOS uses Homebrew. Authentication is
private user state and is never stored in this repository.

## One-time local setup

Create a personal Google OAuth desktop client by following rclone's
[Google Drive client ID guide](https://rclone.org/drive/#making-your-own-client-id).
The shared rclone client is being retired during 2026, so do not leave the
client ID and secret blank on a new configuration.

Run `rclone config` as your normal user, not through `sudo`, and choose:

| Prompt | Value |
|--------|-------|
| Remote name | `gdrive` |
| Storage | Google Drive (`drive`) |
| Client ID / secret | Values from the personal OAuth desktop client |
| Scope | Full access (`drive`) |
| Service account | None |
| Shared Drive | No, unless this account intentionally targets one |

The resulting config is normally `~/.config/rclone/rclone.conf`. It contains
the OAuth refresh token and client credentials, must remain mode `600`, and
must be writable by its owning user so rclone can refresh tokens.

Verify the setup without changing Drive content:

```bash
rclone lsd gdrive: --max-depth 1
```

## Remote deployment

`deploy.sh` scans the local config and offers a default-on **Google Drive
auth** step when `[gdrive]` has the expected Drive backend, full scope,
personal client credentials, and OAuth token. The step runs after remote
`install.sh`, then:

1. Extracts only `[gdrive]` into a mode-`600` temporary file.
2. Atomically replaces that section in the remote config while preserving
   unrelated remotes.
3. Verifies the remote with `rclone lsd gdrive:`.

Encrypted configs cannot be section-merged and require per-host setup. The
same is true when an existing remote config is unreadable or is a symlink;
deployment leaves it unchanged and reports the problem. `--force-copy`
reapplies an otherwise identical profile and permissions.

## Existing node migration

The manually created config on the reference node uses restricted
`drive.file` access and became root-owned because rclone was run through
`sudo`. `install.sh` deliberately does not rewrite it. Before using that node
as a deploy source, recreate or reconnect `gdrive` as the normal user with the
personal client and full `drive` scope, then confirm that the config is owned
by the user and mode `600`.

Uninstall removes only a manifest-owned rclone binary. It preserves the
config, OAuth credentials, and cache.
