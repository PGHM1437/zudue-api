import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { StorageBucket, StorageProvider, PresignedUpload } from './storage-provider.interface';

/** Cloudflare R2 — S3-compatible API, so the AWS SDK works unmodified pointed at R2's endpoint. */
@Injectable()
export class R2Provider extends StorageProvider {
  private readonly client: S3Client;
  private readonly buckets: Record<StorageBucket, string>;

  constructor(private readonly config: ConfigService) {
    super();
    const accountId = this.config.get<string>('R2_ACCOUNT_ID');
    this.client = new S3Client({
      region: 'auto',
      endpoint: accountId ? `https://${accountId}.r2.cloudflarestorage.com` : undefined,
      credentials: {
        accessKeyId: this.config.get<string>('R2_ACCESS_KEY_ID') ?? '',
        secretAccessKey: this.config.get<string>('R2_SECRET_ACCESS_KEY') ?? '',
      },
    });
    this.buckets = {
      kyc: this.config.getOrThrow<string>('R2_BUCKET_KYC'),
      media: this.config.getOrThrow<string>('R2_BUCKET_MEDIA'),
    };
  }

  async getUploadUrl(bucket: StorageBucket, key: string, contentType: string): Promise<PresignedUpload> {
    const expiresInSeconds = 300; // 5 min — long enough for a mobile upload, short enough to limit exposure
    const uploadUrl = await getSignedUrl(
      this.client,
      new PutObjectCommand({ Bucket: this.buckets[bucket], Key: key, ContentType: contentType }),
      { expiresIn: expiresInSeconds },
    );
    return { uploadUrl, key, expiresInSeconds };
  }

  async getDownloadUrl(bucket: StorageBucket, key: string): Promise<string> {
    return getSignedUrl(
      this.client,
      new GetObjectCommand({ Bucket: this.buckets[bucket], Key: key }),
      { expiresIn: 900 }, // 15 min — enough to load a doc or stream a shout-out video
    );
  }
}
