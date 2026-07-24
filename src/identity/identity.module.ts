import { Body, Controller, Get, Injectable, Module, Post, Put, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/**
 * THE single source of truth for "where is this user in their lifecycle".
 *
 * A partner's real state is smeared across profiles.account_status,
 * partner_profiles.status, and partner_applications.status (an inherited,
 * over-normalised schema — profiles.account_status even defaults to ACTIVE for
 * everyone, which is what let unapproved partners bypass onboarding). Rather
 * than have the router, the pending screen, and every guard each re-derive the
 * answer from a different raw field (and pick the wrong one), this CASE
 * resolves all of them here, once, and /me exposes it as `partner_lifecycle`.
 * The client reads ONLY this. Values:
 *   SUSPENDED · NEEDS_APPLICATION · PENDING_INITIAL · AWAITING_COMPLETION ·
 *   PENDING_FINAL · REJECTED · LIVE
 */
const LIFECYCLE_SQL = sql`
  case
    when p.account_status in ('SUSPENDED','BANNED') then 'SUSPENDED'
    when p.role <> 'PARTNER' then 'LIVE'
    when pp.status = 'ACTIVE' then 'LIVE'
    else coalesce((
      select case a.status
        when 'PENDING_INITIAL_REVIEW' then 'PENDING_INITIAL'
        when 'AWAITING_KYC_AND_PROFILE_COMPLETION' then 'AWAITING_COMPLETION'
        when 'PENDING_FINAL_ADMIN_APPROVAL' then 'PENDING_FINAL'
        when 'REJECTED_INITIAL' then 'REJECTED'
        when 'REJECTED_KYC' then 'REJECTED'
        when 'REJECTED_FINAL' then 'REJECTED'
        else 'PENDING_INITIAL' end
      from public.partner_applications a
      where a.profile_id = p.id order by a.submitted_at desc limit 1
    ), 'NEEDS_APPLICATION')
  end`;

@Injectable()
class IdentityService {
  constructor(private readonly db: DatabaseService) {}

  me(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select p.id, p.role, p.full_name, p.email, p.mobile_number, p.age, p.gender,
               p.verification_status, p.account_status, p.referral_code, p.notification_prefs,
               pp.display_name, pp.bio, pp.status as partner_status, pp.is_active,
               pp.vacation_mode, pp.is_premium, pp.is_featured, pp.profile_complete, pp.handle,
               ${LIFECYCLE_SQL} as partner_lifecycle,
               -- Pending deletion is exposed here so the client can offer the
               -- cancel path during the grace period. Without it the app told
               -- users "you can cancel any time" with no way to actually do it.
               (select d.scheduled_purge_at from public.deletion_requests d
                 where d.profile_id = p.id and d.status in ('REQUESTED','CONFIRMED')
                 order by d.requested_at desc limit 1) as deletion_scheduled_purge_at
        from public.profiles p
        left join public.partner_profiles pp on pp.profile_id = p.id
        where p.id = ${userId}
      `)) as unknown as any[];
      return rows[0] ?? null;
    });
  }

  /** Self-signup: creates the profile row (profiles_self_insert RLS, 0028) —
   *  the provision_fan_wallet trigger auto-provisions the wallet. Without this,
   *  a new auth user has no profile row and every other /me call 404s. */
  createProfile(userId: string, b: { fullName: string; email?: string; mobileNumber?: string; role: 'FAN' | 'PARTNER' }) {
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`
        insert into public.profiles (id, role, full_name, email, mobile_number)
        values (${userId}, ${b.role}::public.user_role, ${b.fullName}, ${b.email ?? null}, ${b.mobileNumber ?? null})
        on conflict (id) do nothing
      `);
      if (b.role === 'PARTNER') {
        await tx.execute(sql`
          insert into public.partner_profiles (profile_id, display_name)
          values (${userId}, ${b.fullName})
          on conflict (profile_id) do nothing
        `);
      }
      return { created: true };
    });
  }

  updateProfile(userId: string, patch: Record<string, unknown>) {
    // Only self-editable columns; admin-only columns are blocked by the DB guard.
    return this.db.runAs(userId, async (tx) => {
      // Each column needs the right type at the bind site, because two of these
      // are NOT plain text and drizzle mis-serialises them, which 500'd the
      // whole PUT /me:
      //   gender             -> gender_enum. A string bound as `text` fails enum
      //                         resolution; cast explicitly.
      //   notification_prefs -> jsonb. A JS object bound directly renders as a
      //                         record, not jsonb; stringify + ::jsonb.
      const setters: Record<string, (v: unknown) => any> = {
        full_name: (v) => sql`full_name = ${String(v)}`,
        mobile_number: (v) => sql`mobile_number = ${String(v)}`,
        age: (v) => sql`age = ${v === null || v === '' ? null : Number(v)}`,
        gender: (v) => sql`gender = ${v == null ? null : sql`${v}::public.gender_enum`}`,
        notification_prefs: (v) => sql`notification_prefs = ${JSON.stringify(v)}::jsonb`,
      };
      const parts = Object.entries(patch)
        .filter(([k]) => k in setters)
        .map(([k, v]) => setters[k](v));
      if (!parts.length) return { updated: false };
      await tx.execute(
        sql`update public.profiles set ${sql.join(parts, sql`, `)}, updated_at = now() where id = ${userId}`,
      );
      return { updated: true };
    });
  }

  updatePartnerProfile(userId: string, patch: Record<string, unknown>) {
    return this.db.runAs(userId, async (tx) => {
      const allowed = ['display_name', 'bio', 'profile_image_path', 'vacation_mode', 'profile_complete'];
      const sets = Object.entries(patch).filter(([k]) => allowed.includes(k));
      for (const [k, v] of sets) {
        await tx.execute(sql`update public.partner_profiles set ${sql.identifier(k)} = ${v as any}, updated_at = now() where profile_id = ${userId}`);
      }

      // Coming back from vacation is the moment the waitlist exists for: fans
      // who found this creator unavailable asked to be told when they return.
      // Run inside this same runAs(partner) transaction so the RPC's
      // assert_caller(partner) is satisfied — it is the partner's own fan-out.
      // Safe to call redundantly: it only touches rows still status='WAITING'.
      let notified = 0;
      if (patch.vacation_mode === false) {
        const res = await this.db.rpc(tx, 'rpc_notify_waitlist', [userId]);
        notified = Number(res?.notified ?? 0);
      }
      return { updated: sets.length > 0, waitlistNotified: notified };
    });
  }

  submitKyc(userId: string, documents: unknown[]) {
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_submit_kyc', [sql`${JSON.stringify(documents)}::jsonb` as any]));
  }

  requestDeletion(userId: string, reason?: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_request_account_deletion', [reason ?? null]));
  }

  cancelDeletion(userId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_cancel_account_deletion', []));
  }

  // Partner onboarding — application submission + the two-stage review flow (0034).
  submitApplication(userId: string, b: { applicantFullName: string; email: string; mobileNumber: string; primarySocialLink?: string; expertiseDescription?: string }) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        insert into public.partner_applications (profile_id, applicant_full_name, email, mobile_number, primary_social_link, expertise_description)
        values (${userId}, ${b.applicantFullName}, ${b.email}, ${b.mobileNumber}, ${b.primarySocialLink ?? null}, ${b.expertiseDescription ?? null})
        returning id, status
      `)) as unknown as any[];
      return rows[0];
    });
  }

  myApplication(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select id, status, initial_review_at, final_review_at, admin_notes
        from public.partner_applications where profile_id = ${userId}
        order by submitted_at desc limit 1
      `)) as unknown as any[];
      return rows[0] ?? null;
    });
  }

  submitForReview(userId: string, applicationId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_partner_submit_for_review', [applicationId]));
  }
}

@Controller('me')
class IdentityController {
  constructor(private readonly svc: IdentityService) {}

  @UseGuards(JwtGuard) @Get()
  me(@CurrentUser() u: AuthUser) { return this.svc.me(u.id); }

  @UseGuards(JwtGuard) @Post()
  create(@CurrentUser() u: AuthUser, @Body() b: { fullName: string; email?: string; mobileNumber?: string; role: 'FAN' | 'PARTNER' }) {
    return this.svc.createProfile(u.id, b);
  }

  @UseGuards(JwtGuard) @Put()
  update(@CurrentUser() u: AuthUser, @Body() body: Record<string, unknown>) { return this.svc.updateProfile(u.id, body); }

  @UseGuards(JwtGuard) @Put('partner')
  updatePartner(@CurrentUser() u: AuthUser, @Body() body: Record<string, unknown>) { return this.svc.updatePartnerProfile(u.id, body); }

  @UseGuards(JwtGuard) @Post('kyc')
  kyc(@CurrentUser() u: AuthUser, @Body('documents') documents: unknown[]) { return this.svc.submitKyc(u.id, documents ?? []); }

  @UseGuards(JwtGuard) @Post('deletion')
  del(@CurrentUser() u: AuthUser, @Body('reason') reason?: string) { return this.svc.requestDeletion(u.id, reason); }

  @UseGuards(JwtGuard) @Post('deletion/cancel')
  cancelDel(@CurrentUser() u: AuthUser) { return this.svc.cancelDeletion(u.id); }

  @UseGuards(JwtGuard) @Post('partner/application')
  apply(@CurrentUser() u: AuthUser, @Body() b: { applicantFullName: string; email: string; mobileNumber: string; primarySocialLink?: string; expertiseDescription?: string }) {
    return this.svc.submitApplication(u.id, b);
  }

  @UseGuards(JwtGuard) @Get('partner/application')
  myApp(@CurrentUser() u: AuthUser) { return this.svc.myApplication(u.id); }

  @UseGuards(JwtGuard) @Post('partner/submit-for-review')
  submit(@CurrentUser() u: AuthUser, @Body('applicationId') applicationId: string) { return this.svc.submitForReview(u.id, applicationId); }
}

@Module({ controllers: [IdentityController], providers: [IdentityService] })
export class IdentityModule {}
