import { Global, Injectable, Logger, Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * GoTrue admin API — the one place in this codebase that holds the Supabase
 * service_role key, because deleting an auth.users row (the actual login
 * credential) is only possible through GoTrue's admin endpoint; there is no
 * SQL path to it (auth.users is managed by GoTrue, not app-owned schema).
 *
 * Without this, `rpc_purge_profile`'s anonymisation was the END of account
 * deletion: the profile row said "Deleted user" but the original email +
 * password could still sign in and land on that anonymised, inactive
 * profile. Same optional-integration shape as FcmProvider/RazorpayProvider —
 * unset means the purge sweep still anonymises data, but logs loudly that the
 * credential itself was left behind rather than silently pretending success.
 */
@Injectable()
export class SupabaseAdminProvider {
  private readonly log = new Logger(SupabaseAdminProvider.name);
  private readonly baseUrl: string;
  private readonly serviceRoleKey: string;
  readonly enabled: boolean;

  constructor(config: ConfigService) {
    // AUTH_ISSUER is already `https://<ref>.supabase.co/auth/v1` (verified
    // against this project's live JWKS/issuer config) — GoTrue mounts its
    // admin routes under that same base, so no separate SUPABASE_URL is
    // needed and there is nothing new that could drift out of sync with it.
    this.baseUrl = config.get<string>('AUTH_ISSUER') ?? '';
    this.serviceRoleKey = config.get<string>('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    this.enabled = !!this.baseUrl && !!this.serviceRoleKey;
    if (!this.enabled) {
      this.log.warn('SUPABASE_SERVICE_ROLE_KEY not configured — account purge will anonymise profile data but leave the login credential intact');
    }
  }

  /**
   * Hard-deletes the auth.users row (default GoTrue behaviour — no
   * `should_soft_delete`). Correct here specifically because this only runs
   * after the 30-day cancellable grace period (rpc_cancel_account_deletion)
   * has already elapsed; that window WAS the recoverability period.
   *
   * Returns false (never throws) on failure — the caller decides whether a
   * failed credential-delete should also fail the profile purge.
   */
  async deleteUser(userId: string): Promise<boolean> {
    if (!this.enabled) return false;
    try {
      const res = await fetch(`${this.baseUrl}/admin/users/${userId}`, {
        method: 'DELETE',
        headers: {
          apikey: this.serviceRoleKey,
          Authorization: `Bearer ${this.serviceRoleKey}`,
        },
      });
      // 404 means the auth user is already gone (a re-run after a prior
      // partial failure, or manual cleanup) — that is the desired end state,
      // not a failure to report.
      if (res.ok || res.status === 404) return true;
      this.log.error(`GoTrue admin delete failed for ${userId}: ${res.status} ${await res.text()}`);
      return false;
    } catch (e) {
      this.log.error(`GoTrue admin delete request failed for ${userId}: ${(e as Error).message}`);
      return false;
    }
  }
}

@Global()
@Module({ providers: [SupabaseAdminProvider], exports: [SupabaseAdminProvider] })
export class SupabaseAdminModule {}
