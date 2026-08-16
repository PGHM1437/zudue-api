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
      // C6 fix (0079): this used to be a direct INSERT into notifications, which
      // violates RLS (a non-admin reporter can't insert a row for recipient_id !=
      // their own session) — and because that insert had no .catch(), the RLS
      // error rolled back the WHOLE transaction, meaning the report above never
      // saved either. rpc_create_notification is SECURITY DEFINER so it bypasses
      // that, looped once per admin (same fan-out as the original SELECT ...
      // WHERE role='ADMIN'). related_entity is deliberately NULL, matching the
      // original 4-column shape — with a value there, the dedup ON CONFLICT would
      // collapse distinct reports against the same target into one notification.
      const admins = (await tx.execute(sql`select id from public.profiles where role = 'ADMIN'`)) as unknown as Array<{ id: string }>;
      for (const admin of admins) {
        await this.db
          .rpc(tx, 'rpc_create_notification', [
            admin.id,
            userId,
            sql`'PLATFORM_ANNOUNCEMENT'::public.notification_event_type_enum` as any,
            'New report filed',
            `A ${b.targetType.toLowerCase()} was reported: ${b.reason}`,
            null,
            null,
            sql`${JSON.stringify({ targetType: b.targetType, targetId: b.targetId })}::jsonb` as any,
          ])
          .catch(() => undefined);
      }
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
