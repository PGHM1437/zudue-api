import { Body, Controller, Get, Module, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

class EarningsService {
  constructor(private readonly db: DatabaseService) {}

  summary(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const [agg] = (await tx.execute(sql`
        select
          coalesce(sum(amount_paise) filter (where status <> 'REVERSED'),0) as lifetime,
          coalesce(sum(amount_paise) filter (where status = 'PENDING_PAYOUT'),0) as pending,
          coalesce(sum(amount_paise) filter (where status = 'PAID'),0) as paid
        from public.partner_earnings where partner_id = ${userId}
      `)) as unknown as any[];
      return agg;
    });
  }

  earnings(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select id, service_type, amount_paise, status, payout_id, settled_at from public.partner_earnings
        where partner_id = ${userId} order by settled_at desc limit 200
      `)) as unknown as any[]);
  }

  payoutHistory(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select id, amount_paise, status, utr, requested_at, processed_at from public.partner_payouts
        where partner_id = ${userId} order by requested_at desc
      `)) as unknown as any[]);
  }

  payoutMethods(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select id, method_type, is_verified, is_primary from public.payout_methods where partner_id = ${userId}
      `)) as unknown as any[]);
  }

  addPayoutMethod(userId: string, b: any) {
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`
        insert into public.payout_methods (partner_id, method_type, account_holder_name, account_number, ifsc_code, bank_name, upi_id)
        values (${userId}, ${b.methodType}, ${b.accountHolderName ?? null}, ${b.accountNumber ?? null}, ${b.ifscCode ?? null}, ${b.bankName ?? null}, ${b.upiId ?? null})
      `);
      return { success: true };
    });
  }

  requestWithdrawal(userId: string, methodId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_create_payout_batch', [userId, methodId]));
  }
}

@Controller('partner/earnings')
class EarningsController {
  constructor(private readonly svc: EarningsService) {}
  @UseGuards(JwtGuard) @Get('summary') summary(@CurrentUser() u: AuthUser) { return this.svc.summary(u.id); }
  @UseGuards(JwtGuard) @Get() list(@CurrentUser() u: AuthUser) { return this.svc.earnings(u.id); }
  @UseGuards(JwtGuard) @Get('payouts') payouts(@CurrentUser() u: AuthUser) { return this.svc.payoutHistory(u.id); }
  @UseGuards(JwtGuard) @Get('methods') methods(@CurrentUser() u: AuthUser) { return this.svc.payoutMethods(u.id); }
  @UseGuards(JwtGuard) @Post('methods') addMethod(@CurrentUser() u: AuthUser, @Body() b: any) { return this.svc.addPayoutMethod(u.id, b); }
  @UseGuards(JwtGuard) @Post('withdraw') withdraw(@CurrentUser() u: AuthUser, @Body('methodId') m: string) { return this.svc.requestWithdrawal(u.id, m); }
}

@Module({ controllers: [EarningsController], providers: [EarningsService] })
export class EarningsModule {}
