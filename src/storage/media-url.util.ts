/**
 * Profile photos (unlike KYC docs and shout-out videos) need to be publicly,
 * durably viewable in Discover — a presigned URL that expires in 15 minutes
 * doesn't work for a feed that gets cached client-side. R2_PUBLIC_MEDIA_URL
 * points at a public bucket/custom domain for the SAME `media` bucket the
 * presigned-upload flow writes into; only reads are public.
 *
 * Degrades safely with no config: returns the raw key, and the client's
 * `img.startsWith('http')` check just falls back to the initials avatar.
 */
export function toPublicMediaUrl(key: string | null, publicBaseUrl: string | undefined): string | null {
  if (!key) return null;
  if (key.startsWith('http://') || key.startsWith('https://')) return key; // already a URL (legacy/manual rows)
  if (!publicBaseUrl) return key;
  return `${publicBaseUrl.replace(/\/$/, '')}/${key}`;
}
