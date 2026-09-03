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
        select fcm_token, onesignal_player_id, platform from public.push_tokens where profile_id = ${fanId}
      `)) as unknown as Array<{ fcm_token: string | null; onesignal_player_id: string | null; platform: string | null }>;

      const fcmTokens = rows
        .filter((r): r is typeof r & { fcm_token: string } => !!r.fcm_token)
        .map((r) => ({ token: r.fcm_token, platform: r.platform ?? undefined }));
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

  /**
   * "You're next in line" alert — a visible push, not the CallKit ring
   * (sendIncomingCall). Fired once, when the partner initiates the call ahead
   * of this fan in their queue.
   */
  async notifyQueueNext(fanId: string, title: string, body: string, data: Record<string, string>) {
    await this.db.runAsService(async (tx) => {
      const rows = (await tx.execute(sql`
        select fcm_token, onesignal_player_id, platform from public.push_tokens where profile_id = ${fanId}
      `)) as unknown as Array<{ fcm_token: string | null; onesignal_player_id: string | null; platform: string | null }>;

      const fcmTokens = rows
        .filter((r): r is typeof r & { fcm_token: string } => !!r.fcm_token)
        .map((r) => ({ token: r.fcm_token, platform: r.platform ?? undefined }));
      const playerIds = rows.map((r) => r.onesignal_player_id).filter((t): t is string => !!t);

      const [dead] = await Promise.all([
        this.fcm.sendNotification(fcmTokens, { title, body }, data),
        this.onesignal.sendNotification(playerIds, title, body, data),
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
        select fcm_token, onesignal_player_id, platform from public.push_tokens where profile_id = ${fanId}
      `)) as unknown as Array<{ fcm_token: string | null; onesignal_player_id: string | null; platform: string | null }>;
      const data = { type: 'call_cancelled', callId };
      const fcmTokens = rows
        .filter((r): r is typeof r & { fcm_token: string } => !!r.fcm_token)
        .map((r) => ({ token: r.fcm_token, platform: r.platform ?? undefined }));
      await Promise.all([
        this.fcm.sendData(fcmTokens, data, 20),
        this.onesignal.sendCall(rows.map((r) => r.onesignal_player_id).filter((t): t is string => !!t), data, 'Call ended', 'Missed call'),
      ]);
    });
  }

  /**
   * Tell both parties a live call has ended — so an open call screen tears
   * down at once instead of waiting for its next 60s heartbeat. Data-only,
   * short TTL; harmless to a device that isn't on the call.
   *
   * `status` is the call_status the server actually resolved this to. It has
   * to travel with the push: without it the receiving client had nothing to go
   * on and assumed COMPLETED_SUCCESSFUL, so a creator whose fan declined — or
   * whose call was written off as a technical drop and refunded — was still
   * shown "Call complete. Your booked call time is complete." The outcome card
   * is the only place either party learns how the call resolved, so it must
   * carry the truth, not the happy case.
   */
  async notifyCallEnded(recipientIds: string[], callId: string, bookingId: string, status: string) {
    const ids = [...new Set(recipientIds.filter(Boolean))];
    if (!ids.length) return;
    await this.db.runAsService(async (tx) => {
      const rows = (await tx.execute(sql`
        select fcm_token, onesignal_player_id, platform from public.push_tokens where profile_id = any(${ids})
      `)) as unknown as Array<{ fcm_token: string | null; onesignal_player_id: string | null; platform: string | null }>;
      const data = { type: 'call_ended', callId, bookingId, status };
      const fcmTokens = rows
        .filter((r): r is typeof r & { fcm_token: string } => !!r.fcm_token)
        .map((r) => ({ token: r.fcm_token, platform: r.platform ?? undefined }));
      await Promise.all([
        this.fcm.sendData(fcmTokens, data, 20),
        this.onesignal.sendNotification(rows.map((r) => r.onesignal_player_id).filter((t): t is string => !!t), 'Call ended', 'Your call has ended.', data),
      ]);
    });
  }
}
