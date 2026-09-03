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
    // ABSOLUTE unix timestamp, NOT a duration — do not "fix" this to a bare
    // 3600. agora-token@2 exports RtcTokenBuilder2, whose JSDoc says these
    // arguments are "the number of seconds elapsed since now", but its
    // implementation contradicts that: buildTokenWithUserAccount does
    //   new AccessToken(appId, cert, 0, tokenExpire)
    // and AccessToken2's constructor assigns `this.expire = expire` verbatim
    // while defaulting issueTs to now — the duration is never added to
    // anything. Decoding a minted token confirms it: passing now+3600 yields
    // expire = now+3600 (correct); passing 3600 yields expire = 3600, i.e. a
    // token that expired in January 1970 and is rejected on every join.
    const expire = Math.floor(Date.now() / 1000) + 3600;
    // uid 0: let the SDK assign one. Nothing attributes by Agora uid.
    const token = RtcTokenBuilder.buildTokenWithUid(appId, cert, room, 0, RtcRole.PUBLISHER, expire, expire);
    return { provider: 'agora', room, token, appId };
  }
}
