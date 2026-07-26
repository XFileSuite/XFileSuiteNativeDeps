# XFileSuite Native Dependencies

![Publish Native Dependencies](https://github.com/XFileSuite/XFileSuiteNativeDeps/actions/workflows/publish-native-deps.yml/badge.svg)

This public repository builds and publishes the native runtime dependencies
distributed with XFileSuite. Keeping this workflow public gives its GitHub
Actions jobs access to the public-repository allowance while keeping the App
source private.

## License

The XFileSuite build scripts, manifests, workflow definitions, and documentation
are proprietary and are published for audit only; see [LICENSE](LICENSE).
Third-party components and generated corresponding-source archives retain their
own upstream licenses.

## What the workflow publishes

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

## Required repository secrets

| Secret | Purpose |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Upload and remove objects in the `xfilesuite-releases` R2 bucket. |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account used by Wrangler. |
| `XFILESUITE_SOURCE_WRITE_TOKEN` | Fine-grained token with Contents read/write on `XFileSuiteSource` and `XFileSuite`; it mirrors manifests after a successful publish. |

The workflow's built-in `GITHUB_TOKEN` publishes releases in this repository.
`XFILESUITE_SOURCE_WRITE_TOKEN` must not be exposed outside GitHub Actions.
