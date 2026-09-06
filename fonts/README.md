# Optional font packages

This directory is the source of truth for optional fonts downloaded by
XFileSuite. Font binaries are Git LFS objects so a normal clone does not add
the full font payload to unrelated build jobs.

`manifest.json` pins each file's upstream revision, length and SHA-256. A
package key includes its digest and is immutable. The only mutable R2 object is
`fonts/manifest-v1.json`, uploaded after every package and license succeeds.

To publish from GitHub, open **Actions → Publish Optional Fonts → Run
workflow**, choose `publish`, and run it from `main`. The workflow validates
every local binary before uploading and never deletes an existing font object.

All current Noto packages are distributed under the SIL Open Font License 1.1.
Their complete license texts are in `licenses/` and are uploaded with the
manifest.
