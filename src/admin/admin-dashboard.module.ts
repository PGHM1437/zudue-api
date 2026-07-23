import { Controller, Get, Module, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { CurrentUser, AuthUser } from '../auth/current-user.decorator';
import { AdminGuard } from './admin.guard';

/**
 * One-row operational KPI snapshot. vw_admin_dashboard_stats was dropped in
 * 0032 ("a KPI tile row is a single-table read the backend does directly") —
 * this replicates its exact shape as a live query, per that migration's own
 * instruction, not a guess at what the dashboard should show.
 */
class AdminDashboardService {
  constructor(private readonly db: DatabaseService) {}

  stats(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const [row] = (await tx.execute(sql`
        select
          (select count(*) from public.profiles where role='FAN') as total_fans,
          (select count(*) from public.partner_profiles where status='ACTIVE') as active_partners,
          (select count(*) from public.profiles where account_status<>'ACTIVE') as suspended_or_banned_users,
          (select count(*) from public.profiles where verification_status='PENDING_VERIFICATION') as pending_kyc,
          (select count(*) from public.partner_applications where status not in ('ACTIVE','REJECTED_INITIAL','REJECTED_KYC','REJECTED_FINAL')) as pending_applications,
          (select count(*) from public.partner_payouts where status in ('REQUESTED','APPROVED','PROCESSING')) as pending_withdrawals,
          (select coalesce(sum(amount_paise),0) from public.partner_payouts where status in ('REQUESTED','APPROVED','PROCESSING')) as pending_withdrawal_amount_paise,
          (select count(*) from public.reports where status in ('PENDING','REVIEWING')) as open_reports,
          (select count(*) from public.disputes where status in ('OPEN','UNDER_REVIEW')) as open_disputes,
          (select count(*) from public.shout_out_requests where status='AWAITING_PARTNER_VIDEO') as shoutouts_awaiting_video,
          (select count(*) from public.bookings where status='BOOKED') as active_bookings,
          (select coalesce(sum(amount_paise),0) from public.transactions where type='TOPUP' and status='SUCCESSFUL') as gross_topups_all_time_paise,
          (select coalesce(sum(balance_paise),0) from public.wallets) as total_wallet_liability_paise,
          (select coalesce(sum(amount_paise),0) from public.partner_earnings where status='PENDING_PAYOUT') as unpaid_partner_earnings_paise
      `)) as unknown as any[];
      return row;
    });
  }
}

@Controller('admin/dashboard')
class AdminDashboardController {
  constructor(private readonly svc: AdminDashboardService) {}
  @UseGuards(JwtGuard, AdminGuard) @Get() stats(@CurrentUser() u: AuthUser) { return this.svc.stats(u.id); }
}

@Module({ controllers: [AdminDashboardController], providers: [AdminDashboardService] })
export class AdminDashboardModule {}
