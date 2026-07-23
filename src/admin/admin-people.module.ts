import { BadRequestException, Body, Controller, Get, Injectable, Module, Param, Post, Query, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { CurrentUser, AuthUser } from '../auth/current-user.decorator';
import { AdminGuard } from './admin.guard';

/** Fans, partners, KYC, and the two-stage partner application review. */
@Injectable()
class AdminPeopleService {
  constructor(private readonly db: DatabaseService) {}

  fans(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_manage_fans order by created_at desc limit 500`)) as unknown as any[]);
  }

  partners(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_manage_partners order by created_at desc limit 500`)) as unknown as any[]);
  }

  /**
   * Promote a fan to creator, or revert. Replaces the public "Become a creator"
   * self-signup: role is an operator decision, and routing it through admin is
   * what stops application spam. SUPER_ADMIN only (enforced in the RPC).
   */
  setUserRole(userId: string, targetUserId: string, role: 'FAN' | 'PARTNER', reason?: string) {
    if (role !== 'FAN' && role !== 'PARTNER') {
      throw new BadRequestException('role must be FAN or PARTNER');
    }
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_admin_set_user_role', [
        userId, targetUserId, sql`${role}::public.user_role` as any, reason ?? null,
      ]));
  }

  setAccountStatus(userId: string, targetUserId: string, status: string, reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_set_account_status', [userId, targetUserId, status, reason ?? null]));
  }

  // ── KYC ──
  pendingKyc(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_pending_kyc_verifications order by kyc_submitted_at asc`)) as unknown as any[]);
  }

  /** vw_admin_kyc_management was dropped in 0032 (single-table read) — direct query, same shape. */
  allKyc(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select p.id as profile_id, p.full_name, p.email, p.role, p.verification_status,
               p.kyc_submitted_at, p.kyc_verified_at, p.kyc_verified_by_admin_id, p.kyc_rejection_reason,
               (select count(*) from public.kyc_documents d where d.profile_id = p.id) as document_count
        from public.profiles p
        where p.verification_status <> 'NOT_SUBMITTED'
        order by p.kyc_submitted_at desc nulls last limit 500
      `)) as unknown as any[]);
  }

  decideKyc(userId: string, targetUserId: string, verified: boolean, reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_manage_kyc', [userId, targetUserId, verified, reason ?? null]));
  }

  // ── Partner applications (two-stage) ──
  pendingApplications(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`select * from public.vw_admin_pending_partner_applications order by submitted_at asc`)) as unknown as any[]);
  }

  /** Stage 1: PENDING_INITIAL_REVIEW -> AWAITING_KYC_AND_PROFILE_COMPLETION | REJECTED_INITIAL. */
  reviewApplication(userId: string, applicationId: string, decision: 'APPROVE' | 'REJECT', reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_review_application', [userId, applicationId, decision, reason ?? null]));
  }

  /** Stage 3: PENDING_FINAL_ADMIN_APPROVAL -> ACTIVE | REJECTED_FINAL. */
  finalApprove(userId: string, applicationId: string, decision: 'APPROVE' | 'REJECT', reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_final_approve_partner', [userId, applicationId, decision, reason ?? null]));
  }

  // ── Partner profile controls ──
  toggleFeatured(userId: string, partnerId: string, on: boolean, reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_toggle_featured', [userId, partnerId, on, reason ?? null]));
  }
  togglePremium(userId: string, partnerId: string, on: boolean, reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_toggle_premium', [userId, partnerId, on, reason ?? null]));
  }
  setCommission(userId: string, partnerId: string, rate: number) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_set_commission', [userId, partnerId, rate]));
  }
  /** The approval queue itself — rpc_admin_approve_social_link existed with no
   *  way to see what was awaiting approval. Unapproved first, oldest first. */
  socialLinks(userId: string, pendingOnly = true) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select sl.id, sl.partner_id, pp.display_name as partner_name,
               sl.platform, sl.url, sl.is_approved, sl.created_at
        from public.partner_social_links sl
        join public.partner_profiles pp on pp.profile_id = sl.partner_id
        ${pendingOnly ? sql`where sl.is_approved = false` : sql``}
        order by sl.is_approved, sl.created_at
        limit 500
      `)) as unknown as any[]);
  }

  approveSocialLink(userId: string, linkId: string, approved: boolean) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_approve_social_link', [userId, linkId, approved]));
  }

  /** Audit trail — written by every admin RPC, previously unreadable. */
  auditLog(userId: string, opts: { action?: string; targetType?: string; limit?: number } = {}) {
    const lim = Math.min(Math.max(Number(opts.limit) || 200, 1), 500);
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select id, created_at, actor_id, actor_name, actor_email, actor_role,
               action, target_type, target_id, old_value, new_value, ip_address
        from public.vw_admin_audit_log
        where true
          ${opts.action ? sql`and action = ${opts.action}` : sql``}
          ${opts.targetType ? sql`and target_type = ${opts.targetType}` : sql``}
        order by created_at desc
        limit ${lim}
      `)) as unknown as any[]);
  }
  resetPayoutMethods(userId: string, partnerId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_admin_reset_payout_methods', [userId, partnerId]));
  }
}

@Controller('admin')
class AdminPeopleController {
  constructor(private readonly svc: AdminPeopleService) {}

  @UseGuards(JwtGuard, AdminGuard) @Get('fans') fans(@CurrentUser() u: AuthUser) { return this.svc.fans(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('partners') partners(@CurrentUser() u: AuthUser) { return this.svc.partners(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('users/:id/role')
  setRole(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { role: 'FAN' | 'PARTNER'; reason?: string }) {
    return this.svc.setUserRole(u.id, id, b.role, b.reason);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('users/:id/status')
  setStatus(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { status: string; reason?: string }) {
    return this.svc.setAccountStatus(u.id, id, b.status, b.reason);
  }

  @UseGuards(JwtGuard, AdminGuard) @Get('kyc/pending') pendingKyc(@CurrentUser() u: AuthUser) { return this.svc.pendingKyc(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Get('kyc') allKyc(@CurrentUser() u: AuthUser) { return this.svc.allKyc(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('kyc/:id/decision')
  decideKyc(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { verified: boolean; reason?: string }) {
    return this.svc.decideKyc(u.id, id, b.verified, b.reason);
  }

  @UseGuards(JwtGuard, AdminGuard) @Get('applications') pendingApplications(@CurrentUser() u: AuthUser) { return this.svc.pendingApplications(u.id); }
  @UseGuards(JwtGuard, AdminGuard) @Post('applications/:id/review')
  review(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { decision: 'APPROVE' | 'REJECT'; reason?: string }) {
    return this.svc.reviewApplication(u.id, id, b.decision, b.reason);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('applications/:id/final-approve')
  finalApprove(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { decision: 'APPROVE' | 'REJECT'; reason?: string }) {
    return this.svc.finalApprove(u.id, id, b.decision, b.reason);
  }

  @UseGuards(JwtGuard, AdminGuard) @Post('partners/:id/featured')
  toggleFeatured(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { on: boolean; reason?: string }) {
    return this.svc.toggleFeatured(u.id, id, b.on, b.reason);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('partners/:id/premium')
  togglePremium(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body() b: { on: boolean; reason?: string }) {
    return this.svc.togglePremium(u.id, id, b.on, b.reason);
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('partners/:id/commission')
  setCommission(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('rate') rate: number) {
    return this.svc.setCommission(u.id, id, rate);
  }
  @UseGuards(JwtGuard, AdminGuard) @Get('social-links')
  socialLinks(@CurrentUser() u: AuthUser, @Query('all') all?: string) {
    return this.svc.socialLinks(u.id, all !== 'true');
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('social-links/:id/approve')
  approveSocialLink(@CurrentUser() u: AuthUser, @Param('id') id: string, @Body('approved') approved: boolean) {
    return this.svc.approveSocialLink(u.id, id, approved);
  }
  @UseGuards(JwtGuard, AdminGuard) @Get('audit-log')
  auditLog(@CurrentUser() u: AuthUser, @Query('action') action?: string, @Query('targetType') targetType?: string, @Query('limit') limit?: string) {
    return this.svc.auditLog(u.id, { action, targetType, limit: limit ? Number(limit) : undefined });
  }
  @UseGuards(JwtGuard, AdminGuard) @Post('partners/:id/reset-payout-methods')
  resetPayoutMethods(@CurrentUser() u: AuthUser, @Param('id') id: string) {
    return this.svc.resetPayoutMethods(u.id, id);
  }
}

@Module({ controllers: [AdminPeopleController], providers: [AdminPeopleService] })
export class AdminPeopleModule {}
