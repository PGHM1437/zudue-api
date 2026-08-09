import { Body, Controller, Injectable, Module, Post, UseGuards } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';
import { R2Provider } from './r2.provider';
import { StorageBucket, StorageProvider } from './storage-provider.interface';

type UploadPurpose = 'kyc' | 'profile_photo';

const PURPOSE_TO_BUCKET: Record<UploadPurpose, StorageBucket> = {
  kyc: 'kyc',
  profile_photo: 'media',
};

/**
 * Generic, purpose-namespaced presigned upload. The key is always rooted at
 * `${purpose}/${callerId}/...` so a user can only ever get a writable URL into
 * their OWN namespace — there is no way to pass an arbitrary key.
 *
 * Shout-out video delivery does NOT go through this module: the partner pastes
 * an externally-hosted link (e.g. Google Drive) directly into
 * `delivered_video_link`, and fans/admins open it as-is — no platform storage
 * or signed URL involved.
 *
 * `kyc` is the only purpose whose files need to be read back later (by an
 * admin reviewing a submission). That read path doesn't exist yet —
 * R2Provider.getDownloadUrl is implemented but has no caller.
 */
@Injectable()
class StorageService {
  constructor(private readonly storage: StorageProvider) {}

  async uploadUrl(userId: string, purpose: UploadPurpose, contentType: string, extension: string) {
    const bucket = PURPOSE_TO_BUCKET[purpose];
    if (!bucket) throw new Error('INVALID_PURPOSE');
    const safeExt = extension.replace(/[^a-z0-9]/gi, '').slice(0, 10) || 'bin';
    const key = `${purpose}/${userId}/${randomUUID()}.${safeExt}`;
    return this.storage.getUploadUrl(bucket, key, contentType);
  }
}

@Controller('storage')
class StorageController {
  constructor(private readonly svc: StorageService) {}

  @UseGuards(JwtGuard) @Post('upload-url')
  uploadUrl(@CurrentUser() u: AuthUser, @Body() b: { purpose: UploadPurpose; contentType: string; extension: string }) {
    return this.svc.uploadUrl(u.id, b.purpose, b.contentType, b.extension);
  }
}

@Module({
  controllers: [StorageController],
  providers: [StorageService, { provide: StorageProvider, useClass: R2Provider }],
  exports: [StorageProvider],
})
export class StorageModule {}
