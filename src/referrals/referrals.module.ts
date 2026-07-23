import { Controller, Get, Injectable, Module, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/** referral_code lives on profiles; crediting is rpc_credit_referral (system-gated,
 *  fired by the referee's first qualifying action — not called from here). */
@Injectable()
class ReferralsService {
  constructor(private readonly db: DatabaseService) {}

  myReferralData(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const [profile] = (await tx.execute(sql`
        select referral_code from public.profiles where id = ${userId}
      `)) as unknown as any[];

      const [counts] = (await tx.execute(sql`
        select
          count(*) as total,
          count(*) filter (where status = 'COMPLETED_REWARDED') as rewarded,
          coalesce(sum(referrer_reward_paise) filter (where referrer_credited_at is not null), 0) as earned_paise
        from public.referrals where referrer_id = ${userId}
      `)) as unknown as any[];

      const [settings] = (await tx.execute(sql`
        select referral_referrer_reward_paise, referral_referee_reward_paise, is_referral_program_active
        from public.platform_settings where id = 1
      `)) as unknown as any[];

      return {
        referralCode: profile?.referral_code ?? null,
        referralCount: Number(counts?.total ?? 0),
        rewardedCount: Number(counts?.rewarded ?? 0),
        earnedPaise: Number(counts?.earned_paise ?? 0),
        referrerRewardPaise: settings?.referral_referrer_reward_paise ?? 0,
        refereeRewardPaise: settings?.referral_referee_reward_paise ?? 0,
        programActive: settings?.is_referral_program_active ?? false,
      };
    });
  }
}

@Controller('referrals')
class ReferralsController {
  constructor(private readonly svc: ReferralsService) {}
  @UseGuards(JwtGuard) @Get('me') mine(@CurrentUser() u: AuthUser) { return this.svc.myReferralData(u.id); }
}

@Module({ controllers: [ReferralsController], providers: [ReferralsService] })
export class ReferralsModule {}
