import { BadRequestException, Body, Controller, ForbiddenException, Get, Injectable, Module, Param, ParseUUIDPipe, Post, Query, UseGuards } from '@nestjs/common';
import { BookCallDto, HeartbeatDto, MarkMissedDto, PreviewPriceDto } from './calls.dto';
import { ConfigService } from '@nestjs/config';
import { sql } from 'drizzle-orm';
import { RtcTokenBuilder, RtcRole } from 'agora-token';
import { DatabaseService, Tx } from '../db/database.service';
import { PushService } from '../push/push.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/**
 * Calls — bold domain. Booking + the call state machine
 * (initiate → ready → join → heartbeat → complete | missed | dropped) with a
 * deterministic deadline. Every state transition is a certified DB RPC; this
 * service adds the Agora token (rented) and exposes read models. Stalled/missed
 * sweeps live in JobsModule (BullMQ), not here.
 */
@Injectable()
class CallsService {
  constructor(
    private readonly db: DatabaseService,
    private readonly config: ConfigService,
    private readonly push: PushService,
  ) {}

  /** C6 fix (0079): cross-user notification inserts (partner→fan, fan→partner)
   *  were being silently blocked by RLS (recipient_id must equal the caller's
   *  own session). rpc_create_notification is SECURITY DEFINER so it bypasses
   *  that. Enum/jsonb args must be cast at the bind site — same reason as the
   *  comment below: a driver-typed `text` fails function resolution. */
  private createCallNotification(
    tx: Tx,
    args: {
      recipientId: string;
      actorId: string;
      eventType: string;
      title: string;
      message: string;
      relatedEntityType: string;
      relatedEntityId: string;
      metadata: object;
    },
  ) {
    return this.db
      .rpc(tx, 'rpc_create_notification', [
        args.recipientId,
        args.actorId,
        sql`${args.eventType}::public.notification_event_type_enum` as any,
        args.title,
        args.message,
        sql`${args.relatedEntityType}::public.notification_related_entity_type_enum` as any,
        args.relatedEntityId,
        sql`${JSON.stringify(args.metadata)}::jsonb` as any,
      ])
      .catch(() => undefined);
  }

  // service_type_enum and call_duration_options_enum args must be cast at the
  // bind site — a driver-typed `text` fails function resolution, which is what
  // 500'd both preview and booking. Same fix as services/markMissed/cancel.
  previewPrice(userId: string, partnerId: string, duration: string, promo?: string) {
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_preview_price', [
        partnerId,
        sql`'VIDEO_CALL'::public.service_type_enum` as any,
        sql`${duration}::public.call_duration_options_enum` as any,
        promo ?? null,
      ]));
  }

  book(userId: string, b: { partnerId: string; date: string; duration: string; note?: string; promo?: string }) {
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_book_video_call', [
        userId,
        b.partnerId,
        sql`${b.date}::date` as any,
        sql`${b.duration}::public.call_duration_options_enum` as any,
        b.note ?? null,
        b.promo ?? null,
      ]));
  }

  myBookings(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select b.id, b.partner_id, pp.display_name as partner_name, b.scheduled_date,
               b.selected_duration, b.price_paise, b.status, b.fan_ready_at, b.meeting_id
        from public.bookings b join public.partner_profiles pp on pp.profile_id = b.partner_id
        where b.fan_id = ${userId} order by b.created_at desc
      `)) as unknown as any[]);
  }

  partnerQueue(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_partner_call_queue where partner_id = ${userId}`)) as unknown as any[]);
  }

  /**
   * Typical calling hours (IST), for the client's own "it's late, are you
   * ready?" confirmation. Display-only — 0078 removed the DB-side block, so
   * this is no longer enforced anywhere; a partner can always proceed.
   */
  operationalHours() {
    return this.db.runAnon(async (tx) => {
      const rows = (await tx.execute(sql`
        select operational_start_hour_ist as start_hour_ist, operational_end_hour_ist as end_hour_ist
        from public.platform_settings where id = 1
      `)) as unknown as Array<{ start_hour_ist: number; end_hour_ist: number }>;
      return rows[0] ?? { start_hour_ist: 9, end_hour_ist: 21 };
    });
  }

  /** Partner's past bookings (everything settled/closed, not the live queue). */
  partnerHistory(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select b.id, b.fan_id, p.full_name as fan_name, b.scheduled_date,
               b.selected_duration, b.price_paise, b.status
        from public.bookings b join public.profiles p on p.id = b.fan_id
        where b.partner_id = ${userId}
          and b.status not in ('BOOKED')
        order by b.scheduled_date desc, b.created_at desc
        limit 200
      `)) as unknown as any[]);
  }

  /**
   * Partner's upcoming calls — booked for a FUTURE date, so not yet actionable
   * in the queue (which is today only). Just a heads-up list on the dashboard.
   */
  partnerUpcoming(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select b.id, b.fan_id, p.full_name as fan_name, b.scheduled_date,
               b.selected_duration, b.price_paise, b.status
        from public.bookings b join public.profiles p on p.id = b.fan_id
        where b.partner_id = ${userId}
          and b.status = 'BOOKED'
          and b.scheduled_date > current_date
        order by b.scheduled_date asc, b.created_at asc
        limit 100
      `)) as unknown as any[]);
  }

  /**
   * Fan self-service cancellation → full refund to wallet, booking cancelled,
   * and the partner's booked_minutes released (all inside the RPC's own
   * transaction). The RPC enforces the rest: assert_caller(fan), status must
   * still be BOOKED, and not past settle_at.
   *
   * The reason is pinned server-side. A fan must not be able to label their own
   * cancellation ADMIN_GOODWILL or DISPUTE — those are different refund classes
   * that drive finance reporting and dispute counts.
   *
   * The enum arg is cast explicitly rather than passed as a bare string: a
   * parameter the driver types as `text` fails function resolution outright
   * ("function rpc_refund_booking(uuid, text) does not exist"), and whether it
   * arrives untyped is a driver implementation detail, not a guarantee.
   */
  async cancelBooking(userId: string, bookingId: string) {
    return this.db.runAs(userId, async (tx) => {
      const res = await this.db.rpc(tx, 'rpc_refund_booking', [bookingId, sql`'FAN_CANCEL'::public.refund_reason` as any]);
      if (res?.success) {
        // Booking status stays BOOKED while a call is ringing (only calls.attempt_status
        // moves to PARTNER_INITIATED), so this refund can land mid-ring — stop it on
        // every registered device, not just the one the fan used to cancel from.
        const rows = (await tx.execute(sql`
          select id from public.calls where booking_id = ${bookingId} and attempt_status in ('PARTNER_INITIATED','IN_PROGRESS')
        `)) as unknown as Array<{ id: string }>;
        for (const c of rows) this.push.cancelCall(userId, c.id).catch(() => undefined);
      }
      return res;
    });
  }

  signalReady(userId: string, bookingId: string) {
    return this.db.runAs(userId, async (tx) => {
      const res = await this.db.rpc(tx, 'rpc_fan_signal_ready', [bookingId]);
      if (res?.success) {
        // Notify the partner that the fan is ready (H8/Area 6).
        // The enum value VIDEO_CALL_FAN_READY_PARTNER already exists but was
        // never written — this is the first code path that creates it.
        const rows = (await tx.execute(sql`
          select b.partner_id, p.full_name
          from public.bookings b
          join public.profiles p on p.id = b.fan_id
          where b.id = ${bookingId}
        `)) as unknown as Array<{ partner_id: string; full_name: string | null }>;
        if (rows[0]) {
          await this.createCallNotification(tx, {
            recipientId: rows[0].partner_id,
            actorId: userId,
            eventType: 'VIDEO_CALL_FAN_READY_PARTNER',
            title: 'Fan is ready',
            message: `${rows[0].full_name ?? 'The fan'} is ready for your call`,
            relatedEntityType: 'booking',
            relatedEntityId: bookingId,
            metadata: { bookingId },
          });
        }
      }
      return res;
    });
  }
  /** Partner starts the attempt, then the fan is RUNG on all their devices. */
  async initiate(userId: string, bookingId: string) {
    return this.db.runAs(userId, async (tx) => {
      const res = await this.db.rpc(tx, 'rpc_partner_initiate_call', [bookingId]);
      if (res?.success) {
        const rows = (await tx.execute(sql`
          select b.fan_id, b.selected_duration, pp.display_name
          from public.bookings b join public.partner_profiles pp on pp.profile_id = b.partner_id
          where b.id = ${bookingId}
        `)) as unknown as Array<{ fan_id: string; selected_duration: string; display_name: string | null }>;
        const info = rows[0];
        if (info) {
          // Creating a persistent in-app notification record BEFORE the push ensures
          // the call attempt is visible if the push is missed.
          await this.createCallNotification(tx, {
            recipientId: info.fan_id,
            actorId: userId,
            eventType: 'VIDEO_CALL_INITIATED_FOR_FAN',
            title: 'Incoming Video Call',
            message: `${info.display_name ?? 'Creator'} is calling you now. Join the call!`,
            relatedEntityType: 'call',
            relatedEntityId: res.call_id,
            metadata: { bookingId, callId: res.call_id, meetingId: res.meeting_id },
          });

          // fire-and-forget: don't make the partner wait on push delivery
          this.push.sendIncomingCall(info.fan_id, {
            callId: res.call_id,
            bookingId,
            meetingId: res.meeting_id,
            callerName: info.display_name ?? 'Creator',
            callerId: userId,
            durationMinutes: parseInt(info.selected_duration, 10) || 5,
          }).catch(() => undefined);

          // Queue-position alert: tell the NEXT fan in this partner's queue (if
          // any) their turn is coming up. Matches legacy's
          // handle_call_status_notifications trigger in scope — single next-fan
          // lookup, not a full per-position queue (see 0080's migration note).
          // Estimated wait uses THIS call's own selected_duration (how long
          // until it finishes, i.e. how long until the next fan is up) rather
          // than the next fan's own booked duration — legacy read the latter,
          // which doesn't actually estimate a wait; this corrects that instead
          // of reproducing it.
          //
          // Excludes the fan just called (not just this booking): nothing in
          // the schema stops the same fan from having a second booking with
          // this partner today, so without this a fan could be told "you're
          // next" about booking B while their phone is mid-ring for booking A.
          const nextRows = (await tx.execute(sql`
            select booking_id, fan_id
            from public.vw_partner_call_queue
            where partner_id = ${userId} and booking_id != ${bookingId} and fan_id != ${info.fan_id}
            limit 1
          `)) as unknown as Array<{ booking_id: string; fan_id: string }>;
          const next = nextRows[0];
          if (next) {
            const waitMinutes = parseInt(info.selected_duration, 10) || 15;
            const title = "You're next in line!";
            const body = `${info.display_name ?? 'Your partner'} is on a call now — you're up next, ~${waitMinutes} min.`;
            const notifyResult = await this.createCallNotification(tx, {
              recipientId: next.fan_id,
              actorId: userId,
              eventType: 'VIDEO_CALL_QUEUE_NEXT_FAN',
              title,
              message: body,
              relatedEntityType: 'booking',
              relatedEntityId: next.booking_id,
              metadata: { bookingId: next.booking_id, currentCallId: res.call_id, estimatedWaitMinutes: waitMinutes },
            });
            // rpc_partner_initiate_call has only a 60s cooldown, not true
            // idempotency — a partner retrying a genuine miss more than 60s
            // later re-enters this whole block. `created` (0081) is false when
            // this is a refresh of an already-sent alert for the same fan +
            // booking, so the durable notification still bumps back to unread,
            // but we don't spam a second push for the same underlying fact.
            if (notifyResult?.created) {
              this.push.notifyQueueNext(next.fan_id, title, body, {
                type: 'queue_next',
                bookingId: next.booking_id,
              }).catch(() => undefined);
            }
          }
        }
      }
      return res;
    });
  }
  join(userId: string, bookingId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_fan_join_call', [bookingId]));
  }
  heartbeat(userId: string, callId: string, actor: 'FAN' | 'PARTNER') {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_call_heartbeat', [callId, actor]));
  }
  complete(userId: string, callId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_complete_call', [callId, false]));
  }
  /** Allow-list: the client sends this value, and it lands in a call_status
   *  enum arg. Validate here so a bad value is a clean 400 rather than a DB
   *  type error surfacing as a 500 — and so no other call_status (e.g.
   *  COMPLETED_SUCCESSFUL) can be forced through the "missed" path. */
  private static readonly MISSED_STATUSES = ['MISSED_FAN_NO_JOIN', 'MISSED_FAN_DECLINED', 'DROPPED_TECHNICAL_ISSUE'];

  markMissed(userId: string, callId: string, status: string) {
    if (!CallsService.MISSED_STATUSES.includes(status)) {
      throw new BadRequestException(`status must be one of ${CallsService.MISSED_STATUSES.join(', ')}`);
    }
    return this.db.runAs(userId, async (tx) => {
      const res = await this.db.rpc(tx, 'rpc_mark_call_missed', [callId, sql`${status}::public.call_status` as any]);
      if (res?.success) {
        // Covers the partner declining/dropping a still-ringing call, and the
        // stalled-call sweep. The fan's own CallKit decline/timeout also calls
        // this endpoint — cancelCall back to that same device is a harmless
        // no-op (endCall on an already-dismissed ring).
        const rows = (await tx.execute(sql`select fan_id, booking_id from public.calls where id = ${callId}`)) as unknown as Array<{ fan_id: string; booking_id: string }>;
        if (rows[0]) {
          this.push.cancelCall(rows[0].fan_id, callId).catch(() => undefined);

          // Persist a missed-call notification so the fan sees it even if
          // they dismissed the push. Only for actual miss statuses, not drops.
          if (status === 'MISSED_FAN_NO_JOIN' || status === 'MISSED_FAN_DECLINED') {
            await this.createCallNotification(tx, {
              recipientId: rows[0].fan_id,
              actorId: userId,
              eventType: 'VIDEO_CALL_MISSED_ATTEMPT_FAN',
              title: 'Missed Video Call',
              message: 'You missed a video call. The partner tried to reach you.',
              relatedEntityType: 'call',
              relatedEntityId: callId,
              metadata: { bookingId: rows[0].booking_id, callId, status },
            });
          }
        }
      }
      return res;
    });
  }

  /** Short-lived Agora RTC token for a meeting the caller is a party to. */
  async agoraToken(userId: string, meetingId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select 1 from public.calls where meeting_id = ${meetingId}
          and (fan_id = ${userId} or partner_id = ${userId}) limit 1
      `)) as unknown as any[];
      // ForbiddenException, not a bare Error: a plain Error escapes Nest's
      // exception filter and renders as an opaque 500, so a fan opening a call
      // they aren't party to got "Internal server error" instead of a clear 403.
      if (!rows.length) throw new ForbiddenException('NOT_A_PARTY');
      const appId = this.config.getOrThrow<string>('AGORA_APP_ID');
      const cert = this.config.getOrThrow<string>('AGORA_APP_CERTIFICATE');
      const uid = 0; // string-account tokens could use userId; 0 = let SDK assign
      const expire = Math.floor(Date.now() / 1000) + 3600;
      const token = RtcTokenBuilder.buildTokenWithUid(appId, cert, meetingId, uid, RtcRole.PUBLISHER, expire, expire);
      return { appId, channel: meetingId, token, uid };
    });
  }
}

@Controller('calls')
class CallsController {
  constructor(private readonly svc: CallsService) {}
  @UseGuards(JwtGuard) @Get('preview') preview(@CurrentUser() u: AuthUser, @Query() q: PreviewPriceDto) {
    return this.svc.previewPrice(u.id, q.partnerId, q.duration, q.promo);
  }
  @UseGuards(JwtGuard) @Post('book') book(@CurrentUser() u: AuthUser, @Body() b: BookCallDto) { return this.svc.book(u.id, b); }
  @UseGuards(JwtGuard) @Get('bookings') bookings(@CurrentUser() u: AuthUser) { return this.svc.myBookings(u.id); }
  @UseGuards(JwtGuard) @Get('operational-hours') operationalHours() { return this.svc.operationalHours(); }
  @UseGuards(JwtGuard) @Get('queue') queue(@CurrentUser() u: AuthUser) { return this.svc.partnerQueue(u.id); }
  @UseGuards(JwtGuard) @Get('history') history(@CurrentUser() u: AuthUser) { return this.svc.partnerHistory(u.id); }
  @UseGuards(JwtGuard) @Get('upcoming') upcoming(@CurrentUser() u: AuthUser) { return this.svc.partnerUpcoming(u.id); }
  // bookingId/callId are uuid columns — ParseUUIDPipe turns a malformed id into
  // a clean 400 instead of a Postgres 22P02 surfacing as a bare 500.
  // `:meetingId` is exempt: calls.meeting_id is text ('zudue-<uuid>'), not uuid.
  @UseGuards(JwtGuard) @Post(':bookingId/cancel') cancel(@CurrentUser() u: AuthUser, @Param('bookingId', ParseUUIDPipe) id: string) { return this.svc.cancelBooking(u.id, id); }
  @UseGuards(JwtGuard) @Post(':bookingId/ready') ready(@CurrentUser() u: AuthUser, @Param('bookingId', ParseUUIDPipe) id: string) { return this.svc.signalReady(u.id, id); }
  @UseGuards(JwtGuard) @Post(':bookingId/initiate') init(@CurrentUser() u: AuthUser, @Param('bookingId', ParseUUIDPipe) id: string) { return this.svc.initiate(u.id, id); }
  @UseGuards(JwtGuard) @Post(':bookingId/join') join(@CurrentUser() u: AuthUser, @Param('bookingId', ParseUUIDPipe) id: string) { return this.svc.join(u.id, id); }
  @UseGuards(JwtGuard) @Post('call/:callId/heartbeat') hb(@CurrentUser() u: AuthUser, @Param('callId', ParseUUIDPipe) id: string, @Body() b: HeartbeatDto) { return this.svc.heartbeat(u.id, id, b.actor); }
  @UseGuards(JwtGuard) @Post('call/:callId/complete') done(@CurrentUser() u: AuthUser, @Param('callId', ParseUUIDPipe) id: string) { return this.svc.complete(u.id, id); }
  @UseGuards(JwtGuard) @Post('call/:callId/missed') miss(@CurrentUser() u: AuthUser, @Param('callId', ParseUUIDPipe) id: string, @Body() b: MarkMissedDto) { return this.svc.markMissed(u.id, id, b.status); }
  @UseGuards(JwtGuard) @Get('token/:meetingId') token(@CurrentUser() u: AuthUser, @Param('meetingId') m: string) { return this.svc.agoraToken(u.id, m); }
}

@Module({ controllers: [CallsController], providers: [CallsService] })
export class CallsModule {}
