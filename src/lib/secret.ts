/** Constant-time compare for admin ingest secrets. Length mismatch is false. */
export function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const left = enc.encode(a);
  const right = enc.encode(b);
  if (left.length !== right.length) return false;
  let out = 0;
  for (let i = 0; i < left.length; i += 1) out |= left[i] ^ right[i];
  return out === 0;
}

export function readAdminSecret(headerSecret: string | undefined, authorization: string | undefined): string {
  const fromHeader = headerSecret?.trim() ?? "";
  if (fromHeader) return fromHeader;
  const auth = authorization?.trim() ?? "";
  if (auth.toLowerCase().startsWith("bearer ")) return auth.slice(7).trim();
  return "";
}
