import { Body, Controller, Get, Module, Param, Post, Query, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { CurrentUser, AuthUser } from '../auth/current-user.decorator';
import { AdminGuard } from './admin.guard';

/**
 * Money oversight: wallet-ins (payments), the ledger (transactions), payouts,
 * disputes, promo codes, referrals. vw_admin_payments/_transactions/_disputes/
 * _promo_codes/_referrals were all dropped in 0032 — direct reads here, same
 * shape as their 0030 originals (verified live against production, not just
 * the migration file, before writing these).
 */
class AdminFinanceService {
  constructor(private readonly db: DatabaseService) {}

  walletOverview(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_wallet_overview`)) as unknown as any[]);
  }

  payments(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select o.id as topup_id, o.profile_id, p.full_name as fan_name, p.email,
               o.credit_paise, o.gst_paise, o.amount_paise, o.status,
               o.razorpay_order_id, o.razorpay_payment_id, o.error_message,
               o.transaction_id, o.created_at, o.updated_at
        from public.topup_orders o join public.profiles p on p.id = o.profile_id
        order by o.created_at desc limit 500
      `)) as unknown as any[]);
  }

  transactions(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select t.id as transaction_id, t.type, t.status, t.amount_paise, t.refund_reason,
               t.external_ref, t.created_at,
               (select w.profile_id from public.ledger_entries le join public.wallets w on w.id = le.wallet_id
                  where le.transaction_id = t.id limit 1) as wallet_profile_id,
               (select string_agg(le.account || ':' || le.delta_paise, ', ' order by le.account)
                  from public.ledger_entries le where le.transaction_id = t.id) as ledger_legs
        from public.transactions t
        order by t.created_at desc limit 500
      `)) as unknown as any[]);
  }

  grantCredit(userId: string, profileId: string, amountPaise: number, source: string, reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_grant_credit', [userId, profileId, amountPaise, source, reason ?? null]));
  }

  // ── Payouts ──
  pendingWithdrawals(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_pending_withdrawals order by requested_at asc`)) as unknown as any[]);
  }
  processedPayouts(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_processed_payouts order by processed_at desc limit 500`)) as unknown as any[]);
  }
  verifyPayoutMethod(userId: string, methodId: string, verified: boolean) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_verify_payout_method', [userId, methodId, verified]));
  }

  /**
   * Approve or reject a requested payout. This is the RPC that actually moves
   * money OUT: on approve it posts the PAYOUT_DEBIT ledger legs (partner_payable
   * → razorpay_clearing) and marks the payout + its earnings PAID; on reject it
   * releases the earnings back to PENDING_PAYOUT. The bank transfer itself is
   * done out-of-band (bank/UPI), so the UTR recorded here is the only link
   * between "marked paid" and money actually leaving the bank.
   *
   * The UTR rules live in the RPC, not here — required on approve, format
   * checked, and unique across payouts so the same bank reference cannot close
   * two of them. Validating only in the UI would leave every other caller
   * (ops tooling, a retry, a future endpoint) unprotected.
   * FINANCE/SUPER_ADMIN only (enforced inside the RPC).
   */
  processPayout(userId: string, payoutId: string, approve: boolean, utr?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_process_payout', [payoutId, approve, utr ?? null]));
  }

  // ── Disputes (chargebacks) ──
  disputes(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select d.id, d.transaction_id, d.razorpay_dispute_id, d.amount_paise, d.reason,
               d.status, d.opened_at, d.resolved_at,
               (select w.profile_id from public.ledger_entries le join public.wallets w on w.id = le.wallet_id
                  where le.transaction_id = d.transaction_id limit 1) as affected_profile_id
        from public.disputes d
        order by d.opened_at desc limit 500
      `)) as unknown as any[]);
  }
  resolveDispute(userId: string, disputeId: string, status: string, notes?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_resolve_dispute', [userId, disputeId, status, notes ?? null]));
  }

  /**
   * Who actually received promo cash. Promos are platform-funded (0042), so
   * this is real marketing spend per fan, not a discount the creator absorbed.
   * promo_code_usages has recorded it since 0006; nothing ever read it.
   * Optional ?code= narrows to a single campaign.
   */
  promoBeneficiaries(userId: string, code?: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select usage_id, code, discount_type, fan_id, fan_name, fan_email,
               discount_paise, transaction_id, used_at,
               booking_id, booking_status, original_price_paise, fan_paid_paise
        from public.vw_admin_promo_beneficiaries
        ${code ? sql`where code = ${code}` : sql``}
        order by used_at desc
        limit 500
      `)) as unknown as any[]);
  }

  // ── Promo codes ──
  promoCodes(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select pc.id, pc.code, pc.description, pc.discount_type, pc.discount_value, pc.applies_to,
               pc.max_uses_total, pc.max_uses_per_user, pc.current_total_uses,
               pc.min_booking_paise, pc.start_date, pc.expiry_date, pc.is_active,
               (select count(distinct u.fan_id) from public.promo_code_usages u where u.promo_code_id = pc.id) as unique_users,
               (select coalesce(sum(u.discount_paise),0) from public.promo_code_usages u where u.promo_code_id = pc.id) as total_discount_given_paise,
               (case when not pc.is_active then 'INACTIVE'
                     when pc.expiry_date is not null and pc.expiry_date < now() then 'EXPIRED'
                     when pc.max_uses_total is not null and pc.current_total_uses >= pc.max_uses_total then 'EXHAUSTED'
                     else 'ACTIVE' end) as effective_status,
               pc.created_at
        from public.promo_codes pc
        order by pc.created_at desc
      `)) as unknown as any[]);
  }
  createPromo(userId: string, b: { code: string; type: string; value: number; applies?: string; maxTotal?: number; maxPerUser?: number; expiry?: string }) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_create_promo', [
      userId, b.code, b.type, b.value, b.applies ?? 'ALL', b.maxTotal ?? null, b.maxPerUser ?? null, b.expiry ?? null,
    ]));
  }
  setPromoActive(userId: string, promoId: string, active: boolean) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_set_promo_active', [userId, promoId, active]));
  }

  // ── Referrals ──
  referrals(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select r.id, r.referrer_id, rp.full_name as referrer_name, rp.email as referrer_email,
               r.referee_id, ep.full_name as referee_name, ep.email as referee_email,
               r.code_used, r.status, r.referrer_reward_paise, r.referee_reward_paise,
               r.referrer_credited_at, r.referee_credited_at, r.created_at
        from public.referrals r
        join public.profiles rp on rp.id = r.referrer_id
        left join public.profiles ep on ep.id = r.referee_id
        order by r.created_at desc limit 500
      `)) as unknown as any[]);
  }
}

@Controller('admin')
class AdminFinanceController {
  constructor(private readonly svc: AdminFinanceService) {}

  @UseGuards(JwtGuard, AdminGuard) @Get('wallet-overview') walletOverview(@CurrentUser() u: AuthUser) { return this.svc.walletOverview(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('payments') payments(@CurrentUser() u: AuthUser) { return this.svc.payments(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('transactions') transactions(@CurrentUser() u: AuthUser) { return this.svc.transactions(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('credits/grant')
  grantCredit(@CurrentUser() u: AuthUser, @Body() b: { profileId: string; amountPaise: number; source: string; reason?: string }) {
    return this.svc.grantCredit(u.id, b.profileId, b.amountPaise, b.source, b.reason);
  }

  @UseGuards(JwtGuard, AdminGuard) @Get('withdrawals/pending') pendingWithdrawals(@CurrentUser() u: AuthUser) { return this.svc.pendingWithdrawals(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('payouts/processed') processedPayouts(@CurrentUser() u: AuthUser) { return this.svc.processedPayouts(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('payout-methods/:id/verify')
  verifyPayoutMethod(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('verified') verified: boolean) {
    return this.svc.verifyPayoutMethod(u.id, id, verified);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('payouts/:id/process')
  processPayout(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { approve: boolean; utr?: string; reference?: string }) {
    // `reference` accepted as a legacy alias so an in-flight admin build keeps working.
    return this.svc.processPayout(u.id, id, b.approve, b.utr ?? b.reference);
  }

  @UseGuards(JwtGuard, AdminGuard) @Get('disputes') disputes(@CurrentUser() u: AuthUser) { return this.svc.disputes(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('disputes/:id/resolve')
  resolveDispute(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { status: string; notes?: string }) {
    return this.svc.resolveDispute(u.id, id, b.status, b.notes);
  }

  @UseGuards(JwtGuard, AdminGuard) @Get('promo-codes') promoCodes(@CurrentUser() u: AuthUser) { return this.svc.promoCodes(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('promo-beneficiaries') promoBeneficiaries(@CurrentUser() u: AuthUser, @Query('code') code?: string) {
    return this.svc.promoBeneficiaries(u.id, code);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('promo-codes') createPromo(@CurrentUser() u: AuthUser, @Body() b: any) { return this.svc.createPromo(u.id, b); }
  @UseGuards(JwtGuard, AdminGuard) @Post('promo-codes/:id/active')
  setPromoActive(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('active') active: boolean) {
    return this.svc.setPromoActive(u.id, id, active);
  }

  @UseGuards(JwtGuard, AdminGuard) @Get('referrals') referrals(@CurrentUser() u: AuthUser) { return this.svc.referrals(u.id); }
}

@Module({ controllers: [AdminFinanceController], providers: [AdminFinanceService] })
export class AdminFinanceModule {}
