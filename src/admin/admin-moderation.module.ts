import { Body, Controller, Get, Injectable, Module, Param, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { CurrentUser, AuthUser } from '../auth/current-user.decorator';
import { AdminGuard } from './admin.guard';

/** Reports queue (dropped view in 0032 — direct read) + content oversight. */
@Injectable()
class AdminModerationService {
  constructor(private readonly db: DatabaseService) {}

  reportsQueue(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select r.id, r.reporter_id, rp.full_name as reporter_name,
               r.target_type, r.target_id, r.reason, r.details, r.status,
               r.resolution, r.refund_paise, r.resolved_by, xp.full_name as resolved_by_name,
               r.resolved_at, r.created_at
        from public.reports r
        join public.profiles rp on rp.id = r.reporter_id
        left join public.profiles xp on xp.id = r.resolved_by
        order by r.created_at desc limit 500
      `)) as unknown as any[]);
  }

  resolveReport(userId: string, reportId: string, status: string, resolution?: string, refundPaise?: number) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_resolve_report', [userId, reportId, status, resolution ?? null, refundPaise ?? null]));
  }

  resolveShoutoutReport(userId: string, shoutoutId: string, action: string, notes?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_resolve_shoutout_report', [userId, shoutoutId, action, notes ?? null]));
  }

  /**
   * Review a partner-submitted shout-out video. Delivery is offline (the admin
   * emails/sends the video); this records the outcome. approve → delivered to
   * fan (which lets settlement pay the creator); reject → back to the partner
   * with a note to resubmit.
   */
  deliverShoutout(userId: string, shoutoutId: string, approve: boolean, note?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_deliver_shoutout', [userId, shoutoutId, approve, note ?? null]));
  }

  // ── Content oversight ──
  videoCalls(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_all_video_calls order by scheduled_date desc limit 500`)) as unknown as any[]);
  }
  shoutouts(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_all_shout_outs order by created_at desc limit 500`)) as unknown as any[]);
  }
  questions(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_manage_questions order by opened_at desc limit 500`)) as unknown as any[]);
  }
  setServicePlatformAvailability(userId: string, serviceId: string, available: boolean) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_set_service_platform_availability', [userId, serviceId, available]));
  }
}

@Controller('admin')
class AdminModerationController {
  constructor(private readonly svc: AdminModerationService) {}

  @UseGuards(JwtGuard, AdminGuard) @Get('reports') reports(@CurrentUser() u: AuthUser) { return this.svc.reportsQueue(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('reports/:id/resolve')
  resolveReport(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { status: string; resolution?: string; refundPaise?: number }) {
    return this.svc.resolveReport(u.id, id, b.status, b.resolution, b.refundPaise);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('shoutouts/:id/resolve-report')
  resolveShoutoutReport(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { action: string; notes?: string }) {
    return this.svc.resolveShoutoutReport(u.id, id, b.action, b.notes);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('shoutouts/:id/deliver')
  deliverShoutout(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { approve: boolean; note?: string }) {
    return this.svc.deliverShoutout(u.id, id, b.approve, b.note);
  }

  @UseGuards(JwtGuard, AdminGuard) @Get('video-calls') videoCalls(@CurrentUser() u: AuthUser) { return this.svc.videoCalls(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('shoutouts') shoutouts(@CurrentUser() u: AuthUser) { return this.svc.shoutouts(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('questions') questions(@CurrentUser() u: AuthUser) { return this.svc.questions(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('services/:id/platform-availability')
  setServiceAvailability(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('available') available: boolean) {
    return this.svc.setServicePlatformAvailability(u.id, id, available);
  }
}

@Module({ controllers: [AdminModerationController], providers: [AdminModerationService] })
export class AdminModerationModule {}
