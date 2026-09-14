import { copyFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import path from "node:path"

const projectRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
)

await copyFile(
  path.join(projectRoot, "dist", "403", "index.html"),
  path.join(projectRoot, "dist", "403.html")
)

console.log("Generated dist/403.html for web-server error mapping")
