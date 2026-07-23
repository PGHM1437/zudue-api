import { Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { FcmProvider } from './fcm.provider';
import { OneSignalProvider } from './onesignal.provider';

export interface RegisterTokenDto {
  fcmToken?: string;
  onesignalPlayerId?: string;
  platform?: string;
  deviceInfo?: Record<string, unknown>;
}

export interface IncomingCall {
  callId: string;
  bookingId: string;
  meetingId: string;
  callerName: string;
  callerId: string;
  durationMinutes: number;
}

@Injectable()
export class PushService {
  private readonly log = new Logger(PushService.name);

  constructor(
    private readonly db: DatabaseService,
    private readonly fcm: FcmProvider,
    private readonly onesignal: OneSignalProvider,
  ) {}

  /** Device registers/refreshes its token(s) on login and on token rotation. */
  registerToken(userId: string, dto: RegisterTokenDto) {
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`
        insert into public.push_tokens (profile_id, fcm_token, onesignal_player_id, platform, device_info, last_seen_at)
        values (${userId}, ${dto.fcmToken ?? null}, ${dto.onesignalPlayerId ?? null},
                ${dto.platform ?? 'android'}, ${JSON.stringify(dto.deviceInfo ?? {})}::jsonb, now())
        on conflict (profile_id, fcm_token) where fcm_token is not null
        do update set onesignal_player_id = excluded.onesignal_player_id,
                      platform = excluded.platform, device_info = excluded.device_info,
                      last_seen_at = now(), updated_at = now()
      `);
      return { success: true };
    });
  }

  /**
   * Ring a fan for an incoming call — the whole point of the dual-provider push.
   * Data-only high-priority via BOTH FCM and OneSignal; client dedupes on callId
   * and raises the full-screen CallKit UI. Runs as the service role so it can
   * read the recipient's tokens (RLS otherwise scopes push_tokens to the owner).
   */
  async sendIncomingCall(fanId: string, call: IncomingCall) {
    const data: Record<string, string> = {
      type: 'incoming_call',
      callId: call.callId,
      bookingId: call.bookingId,
      meetingId: call.meetingId,
      callerName: call.callerName,
      callerId: call.callerId,
      durationMinutes: String(call.durationMinutes),
    };

    await this.db.runAsService(async (tx) => {
      const rows = (await tx.execute(sql`
        select fcm_token, onesignal_player_id from public.push_tokens where profile_id = ${fanId}
      `)) as unknown as Array<{ fcm_token: string | null; onesignal_player_id: string | null }>;

      const fcmTokens = rows.map((r) => r.fcm_token).filter((t): t is string => !!t);
      const playerIds = rows.map((r) => r.onesignal_player_id).filter((t): t is string => !!t);

      const [dead] = await Promise.all([
        this.fcm.sendData(fcmTokens, data),
        this.onesignal.sendCall(playerIds, data, call.callerName, 'Incoming video call'),
      ]);

      if (dead.length) {
        await tx.execute(sql`delete from public.push_tokens where profile_id = ${fanId} and fcm_token = any(${dead})`);
        this.log.log(`pruned ${dead.length} dead FCM tokens for ${fanId}`);
      }
    });
  }

  async cancelCall(fanId: string, callId: string) {
    // Tell the device to stop ringing (fan answered elsewhere / partner cancelled).
    await this.db.runAsService(async (tx) => {
      const rows = (await tx.execute(sql`
        select fcm_token, onesignal_player_id from public.push_tokens where profile_id = ${fanId}
      `)) as unknown as Array<{ fcm_token: string | null; onesignal_player_id: string | null }>;
      const data = { type: 'call_cancelled', callId };
      await Promise.all([
        this.fcm.sendData(rows.map((r) => r.fcm_token).filter((t): t is string => !!t), data, 20),
        this.onesignal.sendCall(rows.map((r) => r.onesignal_player_id).filter((t): t is string => !!t), data, 'Call ended', 'Missed call'),
      ]);
    });
  }
}
