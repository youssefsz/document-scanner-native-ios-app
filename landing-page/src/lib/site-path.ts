export function sitePath(pathname: string): string {
  const relativePath = pathname.replace(/^\/+/, "")
  const basePath = import.meta.env.BASE_URL.endsWith("/")
    ? import.meta.env.BASE_URL
    : `${import.meta.env.BASE_URL}/`

  return `${basePath}${relativePath}`
}
