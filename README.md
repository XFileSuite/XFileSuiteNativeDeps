# XFileSuite Native Dependencies

![Publish Native Dependencies](https://github.com/XFileSuite/XFileSuiteNativeDeps/actions/workflows/publish-native-deps.yml/badge.svg)
![Build macOS](https://github.com/XFileSuite/XFileSuiteNativeDeps/actions/workflows/build-macos.yml/badge.svg)
![Build Windows](https://github.com/XFileSuite/XFileSuiteNativeDeps/actions/workflows/build-windows.yml/badge.svg)
![Sync Cloudflare](https://github.com/XFileSuite/XFileSuiteNativeDeps/actions/workflows/sync-cloudflare.yml/badge.svg)

This public repository builds native runtime dependencies and packages the App
for release. Keeping these workflows public gives GitHub Actions jobs access to
the public-repository allowance while keeping the App source private.

## License

The XFileSuite build scripts, manifests, workflow definitions, and documentation
are proprietary and are published for audit only; see [LICENSE](LICENSE).
Third-party components and generated corresponding-source archives retain their
own upstream licenses.

## What the native-deps workflow publishes

`Publish Native Dependencies` builds selected macOS and Windows components,
creates the corresponding-source archives and checksums, publishes them as
releases in this repository, uploads the runtime artifacts to Cloudflare R2,
and removes the superseded R2 objects only after a successful publish.

The final manifests are committed here, then mirrored to:

- `XFileSuite/XFileSuiteSource` — private App build manifest.
- `XFileSuite/XFileSuite` — public `native-deps/` manifest consumed by public
  distribution metadata.

## Publishing a dependency update

1. Edit `native_deps/manifests/macos.json` and/or `windows.json` on `main`.
2. Open **Actions → Publish Native Dependencies → Run workflow**.
3. Select the component and platform.

Do not edit `binarySha256`, `bundleSha256`, `r2Key`, or `sourceRelease` by
hand. The workflow writes them from the final artifact.

## App packaging

Pushing a `v*` tag on `XFileSuiteSource` dispatches:

1. `Build macOS` / `Build Windows` — checkout that Source tag, fetch native
   runtimes from R2, package installers, upload them to R2 `staging/{tag}/`.
2. `Sync Cloudflare Latest` — wait for macOS staging assets, then dispatch
   `XFileSuiteCloud`.

Do not run App packaging from this repository's own tags; NativeDeps tags are
reserved for corresponding-source dependency releases.

## Required repository secrets

| Secret | Purpose |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Upload and remove objects in the `xfilesuite-releases` R2 bucket. |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account used by Wrangler. |
| `XFILESUITE_SOURCE_WRITE_TOKEN` | Fine-grained token with Contents read/write on `XFileSuiteSource` and `XFileSuite`; it mirrors manifests after a successful native-deps publish, and publishes Windows installer GitHub Releases to `XFileSuite`. |
| `FILEPEEK_REPO_TOKEN` | Read-only Contents on `XFileSuiteSource` so App packaging can checkout a release tag. |
| `XFILESUITECLOUD_DISPATCH_TOKEN` | Dispatch `XFileSuiteCloud` after staging assets are ready. |

The workflow's built-in `GITHUB_TOKEN` publishes corresponding-source releases in this repository.
`XFILESUITE_SOURCE_WRITE_TOKEN` must not be exposed outside GitHub Actions.
