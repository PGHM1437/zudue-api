import { BadRequestException, Body, Controller, Get, Injectable, Module, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { sql } from 'drizzle-orm';
import { RtcTokenBuilder, RtcRole } from 'agora-token';
import { DatabaseService } from '../db/database.service';
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
  cancelBooking(userId: string, bookingId: string) {
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_refund_booking', [bookingId, sql`'FAN_CANCEL'::public.refund_reason` as any]));
  }

  signalReady(userId: string, bookingId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_fan_signal_ready', [bookingId]));
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
          // fire-and-forget: don't make the partner wait on push delivery
          this.push.sendIncomingCall(info.fan_id, {
            callId: res.call_id,
            bookingId,
            meetingId: res.meeting_id,
            callerName: info.display_name ?? 'Creator',
            callerId: userId,
            durationMinutes: parseInt(info.selected_duration, 10) || 5,
          }).catch(() => undefined);
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
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_mark_call_missed', [callId, sql`${status}::public.call_status` as any]));
  }

  /** Short-lived Agora RTC token for a meeting the caller is a party to. */
  async agoraToken(userId: string, meetingId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select 1 from public.calls where meeting_id = ${meetingId}
          and (fan_id = ${userId} or partner_id = ${userId}) limit 1
      `)) as unknown as any[];
      if (!rows.length) throw new Error('NOT_A_PARTY');
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
  @UseGuards(JwtGuard) @Get('preview') preview(@CurrentUser() u: AuthUser, @Query() q: any) {
    return this.svc.previewPrice(u.id, q.partnerId, q.duration, q.promo);
  }
  @UseGuards(JwtGuard) @Post('book') book(@CurrentUser() u: AuthUser, @Body() b: any) { return this.svc.book(u.id, b); }
  @UseGuards(JwtGuard) @Get('bookings') bookings(@CurrentUser() u: AuthUser) { return this.svc.myBookings(u.id); }
  @UseGuards(JwtGuard) @Get('queue') queue(@CurrentUser() u: AuthUser) { return this.svc.partnerQueue(u.id); }
  @UseGuards(JwtGuard) @Get('history') history(@CurrentUser() u: AuthUser) { return this.svc.partnerHistory(u.id); }
  @UseGuards(JwtGuard) @Get('upcoming') upcoming(@CurrentUser() u: AuthUser) { return this.svc.partnerUpcoming(u.id); }
  @UseGuards(JwtGuard) @Post(':bookingId/cancel') cancel(@CurrentUser() u: AuthUser, @Param('bookingId') id: string) { return this.svc.cancelBooking(u.id, id); }
  @UseGuards(JwtGuard) @Post(':bookingId/ready') ready(@CurrentUser() u: AuthUser, @Param('bookingId') id: string) { return this.svc.signalReady(u.id, id); }
  @UseGuards(JwtGuard) @Post(':bookingId/initiate') init(@CurrentUser() u: AuthUser, @Param('bookingId') id: string) { return this.svc.initiate(u.id, id); }
  @UseGuards(JwtGuard) @Post(':bookingId/join') join(@CurrentUser() u: AuthUser, @Param('bookingId') id: string) { return this.svc.join(u.id, id); }
  @UseGuards(JwtGuard) @Post('call/:callId/heartbeat') hb(@CurrentUser() u: AuthUser, @Param('callId') id: string, @Body('actor') actor: any) { return this.svc.heartbeat(u.id, id, actor); }
  @UseGuards(JwtGuard) @Post('call/:callId/complete') done(@CurrentUser() u: AuthUser, @Param('callId') id: string) { return this.svc.complete(u.id, id); }
  @UseGuards(JwtGuard) @Post('call/:callId/missed') miss(@CurrentUser() u: AuthUser, @Param('callId') id: string, @Body('status') s: string) { return this.svc.markMissed(u.id, id, s); }
  @UseGuards(JwtGuard) @Get('token/:meetingId') token(@CurrentUser() u: AuthUser, @Param('meetingId') m: string) { return this.svc.agoraToken(u.id, m); }
}

@Module({ controllers: [CallsController], providers: [CallsService] })
export class CallsModule {}
