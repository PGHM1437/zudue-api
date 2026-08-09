import { BadRequestException, Body, Controller, Get, Injectable, Module, Param, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/**
 * Shout-out customer-satisfaction lifecycle (migration 0061): the partner
 * delivers the video straight to the fan, who may confirm it, request one FREE
 * correction and then PAID correction rounds (fee from wallet to escrow, so
 * the partner is credited at settlement), or raise a dispute to admin. The
 * partner is credited only after confirmation (fan / admin / auto after the
 * review window).
 */
@Injectable()
class ShoutoutsService {
  constructor(private readonly db: DatabaseService) {}

  request(userId: string, b: { partnerId: string; recipient: string; message: string }) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_request_shoutout', [userId, b.partnerId, b.recipient, b.message]));
  }
  /** Partner submits the finished video's link — delivered directly to the fan (initial or correction re-submit). */
  upload(userId: string, id: string, videoPath: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_upload_shoutout', [id, videoPath]));
  }
  report(userId: string, id: string, reason: string) {
    if (!reason || !reason.trim()) {
      throw new BadRequestException('reason is required');
    }
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_report_shoutout', [id, reason]));
  }
  /** Fan accepts the delivered video — releases settlement to the partner. */
  confirm(userId: string, id: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_confirm_shoutout', [userId, id]));
  }
  /** Fan asks for changes: first round free, every later round paid. */
  correction(userId: string, id: string, note: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_request_correction', [userId, id, note]));
  }

  mine(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select s.id, s.partner_id, pp.display_name as partner_name, s.recipient_name,
               s.price_paise, s.status, s.delivered_at, s.created_at,
               s.delivered_video_link, s.fan_confirmed_at, s.free_correction_used_at,
               s.review_deadline_at,
               (select count(*) from public.shoutout_corrections c where c.shoutout_id = s.id) as correction_count,
               (select COALESCE(sum(c.fee_paise), 0) from public.shoutout_corrections c
                 where c.shoutout_id = s.id and c.kind = 'PAID') as paid_correction_fees_paise,
               (select shoutout_correction_fee_paise from public.platform_settings where id = 1) as correction_fee_paise
        from public.shout_out_requests s join public.partner_profiles pp on pp.profile_id = s.partner_id
        where s.fan_id = ${userId} order by s.created_at desc
      `)) as unknown as any[]);
  }
  incoming(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select s.id, s.fan_id, s.recipient_name, s.message_for_partner, s.price_paise, s.status, s.created_at,
               s.delivered_video_link, s.fan_confirmed_at,
               (select c.fan_note from public.shoutout_corrections c
                 where c.shoutout_id = s.id and c.resubmitted_at is null
                 order by c.created_at desc limit 1) as correction_note
        from public.shout_out_requests s where s.partner_id = ${userId} order by s.created_at desc
      `)) as unknown as any[]);
  }
}

@Controller('shoutouts')
class ShoutoutsController {
  constructor(private readonly svc: ShoutoutsService) {}
  @UseGuards(JwtGuard) @Get('mine') mine(@CurrentUser() u: AuthUser) { return this.svc.mine(u.id); }
  @UseGuards(JwtGuard) @Get('incoming') incoming(@CurrentUser() u: AuthUser) { return this.svc.incoming(u.id); }
  @UseGuards(JwtGuard) @Post('request') req(@CurrentUser() u: AuthUser, @Body() b: any) { return this.svc.request(u.id, b); }
  @UseGuards(JwtGuard) @Post(':id/upload') up(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('videoPath') p: string) { return this.svc.upload(u.id, id, p); }
  @UseGuards(JwtGuard) @Post(':id/report') rep(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('reason') r: string) { return this.svc.report(u.id, id, r); }
  @UseGuards(JwtGuard) @Post(':id/confirm') confirm(@CurrentUser() u: AuthUser, @Param('id') id: string) { return this.svc.confirm(u.id, id); }
  @UseGuards(JwtGuard) @Post(':id/correction') correction(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('note') n: string) { return this.svc.correction(u.id, id, n); }
}

@Module({ controllers: [ShoutoutsController], providers: [ShoutoutsService] })
export class ShoutoutsModule {}
