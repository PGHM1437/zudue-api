import { Body, Controller, Get, Injectable, Module, Param, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/**
 * Shout-out delivery is out-of-app: the partner uploads to R2 (see
 * StorageModule), admin reviews the video, and emails it to the fan directly.
 * There is no fan-facing "watch" endpoint — the app only reflects status.
 */
@Injectable()
class ShoutoutsService {
  constructor(private readonly db: DatabaseService) {}

  request(userId: string, b: { partnerId: string; recipient: string; message: string }) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_request_shoutout', [userId, b.partnerId, b.recipient, b.message]));
  }
  /** Partner uploads the finished video (R2 key) — admin reviews it before it's emailed out. */
  upload(userId: string, id: string, videoPath: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_upload_shoutout', [id, videoPath]));
  }
  report(userId: string, id: string, reason: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_report_shoutout', [id, reason]));
  }

  mine(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select s.id, s.partner_id, pp.display_name as partner_name, s.recipient_name,
               s.price_paise, s.status, s.delivered_at, s.created_at
        from public.shout_out_requests s join public.partner_profiles pp on pp.profile_id = s.partner_id
        where s.fan_id = ${userId} order by s.created_at desc
      `)) as unknown as any[]);
  }
  incoming(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select s.id, s.fan_id, s.recipient_name, s.message_for_partner, s.price_paise, s.status, s.created_at
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
}

@Module({ controllers: [ShoutoutsController], providers: [ShoutoutsService] })
export class ShoutoutsModule {}
