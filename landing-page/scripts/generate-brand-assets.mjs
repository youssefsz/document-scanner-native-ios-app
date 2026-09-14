import { mkdir, writeFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"
import path from "node:path"

import sharp from "sharp"

const projectRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
)
const source = path.join(projectRoot, "src/assets/brand/app-icon.png")
const pngAt = (size) =>
  sharp(source)
    .resize(size, size, { fit: "contain" })
    .removeAlpha()
    .png({ compressionLevel: 9 })
    .toBuffer()

await mkdir(path.join(projectRoot, "public/icons"), { recursive: true })
for (const [file, size] of [
  ["src/assets/brand/brand-mark.png", 128],
  ["public/favicon.png", 48],
  ["public/apple-touch-icon.png", 180],
  ["public/icons/icon-192.png", 192],
  ["public/icons/icon-512.png", 512],
]) {
  const output = await pngAt(size)
  await writeFile(path.join(projectRoot, file), output)
  console.log(`Generated ${file} (${size}x${size}, ${output.length} bytes)`)
}

// PNG-backed ICO entries retain the same approved artwork at browser sizes.
const sizes = [16, 32, 48]
const images = await Promise.all(sizes.map(pngAt))
const directory = Buffer.alloc(6 + sizes.length * 16)
directory.writeUInt16LE(1, 2)
directory.writeUInt16LE(sizes.length, 4)
let offset = directory.length
images.forEach((image, index) => {
  const entry = 6 + index * 16
  directory[entry] = sizes[index]
  directory[entry + 1] = sizes[index]
  directory.writeUInt16LE(1, entry + 4)
  directory.writeUInt16LE(24, entry + 6)
  directory.writeUInt32LE(image.length, entry + 8)
  directory.writeUInt32LE(offset, entry + 12)
  offset += image.length
})
await writeFile(
  path.join(projectRoot, "public/favicon.ico"),
  Buffer.concat([directory, ...images])
)
