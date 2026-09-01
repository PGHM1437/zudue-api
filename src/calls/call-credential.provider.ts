import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { RtcTokenBuilder, RtcRole } from 'agora-token';

/**
 * A join credential for the media session, provider-neutral in shape. The
 * client hands `token` / `appId` / `room` straight to the RTC SDK. This is the
 * ONLY place the media provider exists on the server -- swapping to LiveKit or
 * a self-hosted SFU is a new implementation of `mint`, bound in CallsModule.
 */
export interface CallCredential {
  provider: string;
  room: string; // = calls.meeting_id
  token: string;
  appId: string;
}

export abstract class CallCredentialProvider {
  abstract mint(room: string): CallCredential;
}

@Injectable()
export class AgoraCredentialProvider extends CallCredentialProvider {
  constructor(private readonly config: ConfigService) {
    super();
  }

  mint(room: string): CallCredential {
    const appId = this.config.getOrThrow<string>('AGORA_APP_ID');
    const cert = this.config.getOrThrow<string>('AGORA_APP_CERTIFICATE');
    const expire = Math.floor(Date.now() / 1000) + 3600;
    // uid 0: let the SDK assign one. Nothing attributes by Agora uid.
    const token = RtcTokenBuilder.buildTokenWithUid(appId, cert, room, 0, RtcRole.PUBLISHER, expire, expire);
    return { provider: 'agora', room, token, appId };
  }
}
