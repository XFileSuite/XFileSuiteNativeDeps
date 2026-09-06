import { createHash } from "node:crypto";
import { readFile, stat, writeFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = process.cwd();
const manifestPath = resolve(root, "fonts/manifest.json");
const upload = process.argv.includes("--upload");
const bucket = "xfilesuite-releases";
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));

if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.packages)) {
  throw new Error("fonts/manifest.json must use schemaVersion 1 with packages");
}

const seen = new Set();
const licenses = new Map();
for (const item of manifest.packages) {
  const identity = `${item.id}@${item.version}`;
  if (!/^[a-z0-9._-]+$/.test(item.id) || !/^[0-9][a-zA-Z0-9._-]*$/.test(item.version)) {
    throw new Error(`Invalid package identity: ${identity}`);
  }
  if (seen.has(identity)) throw new Error(`Duplicate package: ${identity}`);
  seen.add(identity);
  if (!/^[a-f0-9]{64}$/.test(item.sha256)) {
    throw new Error(`Invalid SHA-256: ${identity}`);
  }
  if (
    item.r2Key !==
    `fonts/packages/${item.id}/${item.version}/${item.sha256}/${item.fileName}`
  ) {
    throw new Error(`R2 key must be content-addressed: ${identity}`);
  }
  const file = resolve(root, "fonts", item.file);
  const bytes = await readFile(file);
  const actualHash = createHash("sha256").update(bytes).digest("hex");
  const actualSize = (await stat(file)).size;
  if (actualHash !== item.sha256 || actualSize !== item.size) {
    throw new Error(`Checksum or size mismatch: ${identity}`);
  }
  const license = resolve(root, "fonts", item.licenseFile);
  await readFile(license);
  licenses.set(item.licenseFile, license);
  console.log(`Verified ${identity}`);
}

const publicManifest = {
  schemaVersion: manifest.schemaVersion,
  license: manifest.license,
  packages: manifest.packages.map(({ file, ...item }) => ({
    ...item,
    licenseKey: `fonts/licenses/${basename(item.licenseFile)}`,
  })),
};
const output = resolve(process.env.RUNNER_TEMP ?? "/tmp", "fonts-manifest-v1.json");
await writeFile(output, `${JSON.stringify(publicManifest, null, 2)}\n`);
console.log(`Wrote ${output}`);

if (!upload) process.exit(0);

function put(key, file, contentType, cacheControl) {
  const result = spawnSync(
    "npx",
    [
      "--yes",
      "wrangler@4.129.0",
      "r2",
      "object",
      "put",
      `${bucket}/${key}`,
      "--remote",
      "--file",
      file,
      "--content-type",
      contentType,
      "--cache-control",
      cacheControl,
    ],
    { stdio: "inherit" },
  );
  if (result.status !== 0) throw new Error(`Unable to upload ${key}`);
}

for (const [licenseFile, path] of licenses) {
  put(
    `fonts/licenses/${basename(licenseFile)}`,
    path,
    "text/plain; charset=utf-8",
    "public, max-age=31536000, immutable",
  );
}
for (const item of manifest.packages) {
  put(
    item.r2Key,
    resolve(root, "fonts", item.file),
    "font/ttf",
    "public, max-age=31536000, immutable",
  );
}
put(
  "fonts/manifest-v1.json",
  output,
  "application/json; charset=utf-8",
  "public, max-age=300, must-revalidate",
);
