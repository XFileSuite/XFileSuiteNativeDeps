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
and leaves earlier content-addressed R2 objects in place by default. For a
full publish, the optional `purge_all_deps` input deletes existing native
dependency objects after both platforms publish, while retaining every object
referenced by the new manifests. Old manifests may still refer to those deleted
objects, so enable it only when those versions no longer need to be downloadable.

The final manifests are committed here, then mirrored to:

- `XFileSuite/XFileSuiteSource` — private App build manifest.
- `XFileSuite/XFileSuite` — public `native-deps/` manifest consumed by public
  distribution metadata.

## Publishing a dependency update

1. Edit `native_deps/manifests/macos.json` and/or `windows.json` on `main`.
2. Open **Actions → Publish Native Dependencies → Run workflow**.
3. Select `mode=build-only` to inspect macOS build artifacts, or `mode=publish`
   to upload and mirror the dependency manifest. Select the component and
   platform. A full `publish` run may also select `purge_all_deps`; this
   requires `component=all` and `platform=all` and defaults to off.

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

The macOS DMG and ZIP require a `Developer ID Application` certificate for team
`MV5NNZW2VB`. The workflow signs the non-sandboxed App, notarizes and staples
the App, then signs, notarizes, and staples the DMG before uploading either package.
Missing signing credentials stop the build before any package is published.
Apple Distribution is for the separate Mac App Store archive, not this DMG.

## Required repository secrets

| Secret | Purpose |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Upload and remove objects in the `xfilesuite-releases` R2 bucket. |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account used by Wrangler. |
| `XFILESUITE_SOURCE_WRITE_TOKEN` | Fine-grained token with Contents read/write on `XFileSuiteSource` and `XFileSuite`; it mirrors manifests after a successful native-deps publish, and publishes Windows installer GitHub Releases to `XFileSuite`. |
| `FILEPEEK_REPO_TOKEN` | Read-only Contents on `XFileSuiteSource` so App packaging can checkout a release tag. |
| `XFILESUITECLOUD_DISPATCH_TOKEN` | Dispatch `XFileSuiteCloud` after staging assets are ready. |
| `MACOS_DEVELOPER_ID_P12_BASE64` | Base64 of a Developer ID Application `.p12` containing the certificate and private key for team `MV5NNZW2VB`. |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | Password used when exporting that `.p12`. |
| `APPLE_NOTARY_KEY_BASE64` | Base64 of the App Store Connect API key `.p8` used by `notarytool`. |
| `APPLE_NOTARY_KEY_ID` | Key ID of that App Store Connect API key. |
| `APPLE_NOTARY_ISSUER_ID` | Issuer ID of the App Store Connect API key. |

The workflow's built-in `GITHUB_TOKEN` publishes corresponding-source releases in this repository.
`XFILESUITE_SOURCE_WRITE_TOKEN` must not be exposed outside GitHub Actions.
Create the Developer ID Application certificate in the Apple Developer account,
export it with its private key from Keychain Access, and add the five signing
values as repository or organization secrets. Keep the `.p12`, `.p8`, and their
passwords out of the repository and release artifacts. A first CI run must
confirm Apple notarization accepts the bundled native frameworks and tools.
