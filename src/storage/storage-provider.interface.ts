export type StorageBucket = 'kyc' | 'media';

export interface PresignedUpload {
  uploadUrl: string; // client PUTs the file bytes directly here
  key: string; // pass this back to the domain RPC/endpoint that references the file
  expiresInSeconds: number;
}

/**
 * Abstracts object storage so R2 (default, no egress fees) can be swapped for
 * S3 without touching domain code. Both buckets are PRIVATE — nothing is
 * publicly readable; every read goes through a short-lived signed URL, since
 * KYC documents and shout-out videos are both personal, paid-for content.
 */
export abstract class StorageProvider {
  /** A short-lived URL the client uploads the raw file bytes to directly (never proxied through our server). */
  abstract getUploadUrl(bucket: StorageBucket, key: string, contentType: string): Promise<PresignedUpload>;

  /** A short-lived URL to read a private object (KYC doc for admin review, shout-out video for the paying fan). */
  abstract getDownloadUrl(bucket: StorageBucket, key: string): Promise<string>;
}
