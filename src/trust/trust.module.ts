import { BadRequestException, Body, Controller, Injectable, Module, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

@Injectable()
class TrustService {
  constructor(private readonly db: DatabaseService) {}

  block(userId: string, blocked: string, scope = 'ALL') {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_block_user', [userId, blocked, scope, false, null]));
  }
  unblock(userId: string, blocked: string, scope = 'ALL') {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_unblock_user', [userId, blocked, scope]));
  }
  /** target_type is a report_target_type enum column — validate here so a bad
   *  value is a clean 400 instead of a DB coercion error surfacing as a 500. */
  private static readonly TARGET_TYPES = ['PROFILE', 'CALL', 'DM', 'MESSAGE', 'SHOUTOUT'];

  report(userId: string, b: { targetType: string; targetId: string; reason: string; details?: string }) {
    if (!TrustService.TARGET_TYPES.includes(b?.targetType)) {
      throw new BadRequestException(`targetType must be one of ${TrustService.TARGET_TYPES.join(', ')}`);
    }
    if (!b?.targetId || !b?.reason?.trim()) {
      throw new BadRequestException('targetId and reason are required');
    }
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`
        insert into public.reports (reporter_id, target_type, target_id, reason, details)
        values (${userId}, ${b.targetType}, ${b.targetId}, ${b.reason}, ${b.details ?? null})
      `);
      // No rpc_report_* exists for PROFILE/CALL/DM/MESSAGE (only shout-outs
      // have one, via rpc_report_shoutout), and this table has no trigger —
      // so filing a report previously reached the admin queue only if an
      // admin happened to poll it. PLATFORM_ANNOUNCEMENT + the 4-column shape
      // (recipient_id, event_type, title, message) is the exact pattern
      // rpc_admin_set_user_role already uses for an admin-facing notice —
      // matched here rather than adding related_entity_type/_id, whose enum
      // values weren't verifiable live at the time this was written.
      await tx.execute(sql`
        insert into public.notifications (recipient_id, event_type, title, message)
        select p.id, 'PLATFORM_ANNOUNCEMENT', 'New report filed',
               ${'A ' + b.targetType.toLowerCase() + ' was reported: ' + b.reason}
        from public.profiles p where p.role = 'ADMIN'
      `);
      return { success: true };
    });
  }
}

@Controller('trust')
class TrustController {
  constructor(private readonly svc: TrustService) {}
  @UseGuards(JwtGuard) @Post('block') block(@CurrentUser() u: AuthUser, @Body() b: { blocked: string; scope?: string }) { return this.svc.block(u.id, b.blocked, b.scope); }
  @UseGuards(JwtGuard) @Post('unblock') unblock(@CurrentUser() u: AuthUser, @Body() b: { blocked: string; scope?: string }) { return this.svc.unblock(u.id, b.blocked, b.scope); }
  @UseGuards(JwtGuard) @Post('report') report(@CurrentUser() u: AuthUser, @Body() b: any) { return this.svc.report(u.id, b); }
}

@Module({ controllers: [TrustController], providers: [TrustService] })
export class TrustModule {}
