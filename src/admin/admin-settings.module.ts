import { Body, Controller, Get, Injectable, Module, Param, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { CurrentUser, AuthUser } from '../auth/current-user.decorator';
import { AdminGuard } from './admin.guard';

/**
 * Admin-user management. The DB enforces SUPER_ADMIN-only via
 * assert_admin_role('SUPER_ADMIN') inside these RPCs — AdminGuard here only
 * gates "is an admin at all"; a non-SUPER_ADMIN admin gets a clear rejection
 * from the RPC itself, same pattern as every other tiered action.
 */
@Injectable()
class AdminSettingsService {
  constructor(private readonly db: DatabaseService) {}

  /** Admins + their tier, for the settings screen's admin-list table. */
  admins(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select p.id as profile_id, p.full_name, p.email, ap.admin_role, ap.permissions, ap.created_at
        from public.admin_profiles ap join public.profiles p on p.id = ap.profile_id
        order by ap.created_at desc
      `)) as unknown as any[]);
  }

  createAdmin(userId: string, targetProfileId: string, role: string, permissions?: Record<string, unknown>) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_create_admin', [userId, targetProfileId, role, JSON.stringify(permissions ?? {})]));
  }

  revokeAdmin(userId: string, targetProfileId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_revoke_admin', [userId, targetProfileId]));
  }

  /**
   * Platform settings. Only the knobs the code ACTUALLY reads are returned —
   * the audit found 14 that nothing consumes, and surfacing those would put
   * switches on the panel that do nothing, which was the original complaint.
   */
  platformSettings(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select gst_rate, default_commission_rate,
               min_wallet_topup_paise, max_wallet_topup_paise, max_wallet_balance_paise,
               min_withdrawal_paise, settlement_window_days, question_sla_hours,
               payout_day_of_month, referral_referrer_reward_paise, referral_referee_reward_paise,
               referral_budget_remaining_paise, is_referral_program_active, min_service_prices,
               updated_at, last_updated_by_admin_id
        from public.platform_settings where id = 1
      `)) as unknown as any[];
      return rows[0] ?? null;
    });
  }

  /** Validation + SUPER_ADMIN/FINANCE gating live in the RPC (0048). */
  updatePlatformSettings(userId: string, patch: Record<string, unknown>) {
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_admin_update_settings', [sql`${JSON.stringify(patch)}::jsonb` as any]));
  }
}

@Controller('admin/settings')
class AdminSettingsController {
  constructor(private readonly svc: AdminSettingsService) {}
  @UseGuards(JwtGuard, AdminGuard) @Get('admins') admins(@CurrentUser() u: AuthUser) { return this.svc.admins(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('admins')
  createAdmin(@CurrentUser() u: AuthUser, @Body() b: { profileId: string; role: string; permissions?: Record<string, unknown> }) {
    return this.svc.createAdmin(u.id, b.profileId, b.role, b.permissions);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('admins/:id/revoke')
  revokeAdmin(@CurrentUser() u: AuthUser, @Param('id') id: string) {
    return this.svc.revokeAdmin(u.id, id);
  }
  @UseGuards(JwtGuard, AdminGuard) @Get('platform') platform(@CurrentUser() u: AuthUser) {
    return this.svc.platformSettings(u.id);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('platform')
  updatePlatform(@CurrentUser() u: AuthUser, @Body() b: Record<string, unknown>) {
    return this.svc.updatePlatformSettings(u.id, b);
  }
}

@Module({ controllers: [AdminSettingsController], providers: [AdminSettingsService] })
export class AdminSettingsModule {}
