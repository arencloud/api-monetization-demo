import { readdirSync, rmSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const pluginRoot = resolve(import.meta.dirname, "..");
const dynamicRoot = resolve(pluginRoot, "dist-dynamic");
const packageManifest = resolve(dynamicRoot, "package.json");

if (!statSync(packageManifest).isFile()) {
  throw new Error(
    "dist-dynamic is missing; run npm run export-dynamic -- --clean first"
  );
}

// The RHDH frontend loader consumes package.json and dist-scalprum. Standard
// webpack output and source maps are development artifacts that would exceed
// Kubernetes' ConfigMap size limit without changing runtime behavior.
rmSync(resolve(dynamicRoot, "dist"), { recursive: true, force: true });

const removeSourceMaps = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      removeSourceMaps(path);
    } else if (entry.name.endsWith(".map")) {
      rmSync(path);
    }
  }
};
removeSourceMaps(resolve(dynamicRoot, "dist-scalprum"));

// Swagger's syntax highlighter emits a chunk for every supported programming
// language. API contracts and responses in this portal only need common web/API
// formats; retaining hundreds of unrelated language chunks would push the
// generated plugin beyond the Kubernetes ConfigMap object-size limit.
const retainedApiLanguages = new Set([
  "bash",
  "http",
  "javascript",
  "json",
  "plaintext",
  "shell",
  "typescript",
  "xml",
  "yaml",
]);
const pruneUnusedSyntaxLanguages = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      pruneUnusedSyntaxLanguages(path);
      continue;
    }

    const match = entry.name.match(
      /^react-syntax-highlighter_languages_highlight_([^.]*)\./
    );
    if (match && !retainedApiLanguages.has(match[1])) {
      rmSync(path);
    }
  }
};
pruneUnusedSyntaxLanguages(resolve(dynamicRoot, "dist-scalprum"));

const destination = resolve(pluginRoot, "../../platform/developer-hub");
const packed = spawnSync(
  "npm",
  ["pack", "--pack-destination", destination, dynamicRoot],
  { cwd: pluginRoot, encoding: "utf8", stdio: "inherit" }
);
if (packed.status !== 0) {
  process.exit(packed.status ?? 1);
}
