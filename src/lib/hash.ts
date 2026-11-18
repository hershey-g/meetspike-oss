export async function sha256Hex(data: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(data));
  return bytesToHex(new Uint8Array(buf));
}

export function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(value);
}

export function r2Key(source: string, endpoint: string, documentId: string, contentHash: string): string {
  return `${source}/${endpoint}/${documentId}/${contentHash}.json`;
}
