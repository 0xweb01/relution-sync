# relution-sync

# relution-sync

Upload macOS `.pkg` and iOS `.ipa` packages to a [Relution](https://www.relution.io/) app store from the command line.

Relution does not publish documentation for its content REST API. This script implements the upload flow used by the Relution web console: it registers a chunked upload, streams the file, parses it into an app definition, and persists the app. Uploading a new app — or a new version of an existing app — takes about a minute, instead of several minutes of clicking through the web UI.

## Features

- Chunked upload of large packages
- Works for new apps and for new versions of existing apps
- Adds a display name automatically for packages that ship without one (common for macOS `.pkg`)
- Fails fast and prints the server's response on any error

## Requirements

- `bash`
- `curl` 7.76 or newer (for `--fail-with-body`)
- `jq`

## Access token

In Relution, open your profile and create an API access token (Profile → Access Tokens). It is sent as the `X-User-Access-Token` header.

## Configuration

The script reads two environment variables:

| Variable | Description |
| --- | --- |
| `RELUTION_HOST` | Base URL, e.g. `https://relution.example.com` |
| `RELUTION_ACCESS_TOKEN` | API access token |

## Usage

```bash
chmod +x relution-sync.sh

export RELUTION_HOST="https://relution.example.com"
export RELUTION_ACCESS_TOKEN="your-token"

# Upload a package; the display name defaults to the file name
./relution-sync.sh ./Firefox.pkg

# Provide an explicit display name
./relution-sync.sh ./Firefox.pkg "Firefox"

# iOS
./relution-sync.sh ./MyApp.ipa "My App"
```

Run `./relution-sync.sh --help` for a short reminder.

## Notes

- **Use `.pkg` for macOS, not `.dmg`.** A `.pkg` installs through the macOS installer with the correct privileges. Deploying a raw `.dmg` requires the management agent to copy the `.app` into `/Applications`, which commonly fails with `Operation not permitted`. If an app ships only as a `.dmg`, wrap it into a `.pkg` first (see below).
- New uploads enter the **Development** state and are not distributed to devices until promoted to Productive in Relution.
- Identical content is detected by hash on the server, so re-uploading the same file transfers nothing.

### Wrapping a `.dmg` into a `.pkg`

For apps distributed only as a disk image, build a package on macOS:

```bash
hdiutil attach App.dmg
mkdir -p /tmp/payload/Applications
ditto "/Volumes/App/App.app" "/tmp/payload/Applications/App.app"
hdiutil detach "/Volumes/App"

pkgbuild --root /tmp/payload \
  --identifier com.example.app \
  --version 1.0 \
  --install-location / \
  App.pkg
```

## How it works

The upload is a four-step sequence against `…/api/management/v1`:

1. `POST …/content/apps/versions/file/upload` — register the upload and receive a resource UUID and the first chunk window.
2. `POST …/content/apps/versions/file/upload/{uuid}` — stream the file chunk by chunk until the server returns a negative offset.
3. `POST …/content/apps/fromFile/{uuid}` — parse the uploaded binary into an app definition.
4. `POST …/content/apps` — persist the app.
