import { Body, Controller, Get, Module, Post, Query, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

class AvailabilityService {
  constructor(private readonly db: DatabaseService) {}

  /** Partner sets a date's open minutes. Default is none unless set. */
  set(userId: string, date: string, minutes: number) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_partner_set_availability', [userId, date, minutes]));
  }

  /** Public — a partner's bookable dates (for the fan's booking calendar). */
  forPartner(partnerId: string) {
    return this.db.runAnon(async (tx) =>
      (await tx.execute(sql`
        select date, is_available, threshold_minutes, booked_minutes
        from public.availability
        where partner_id = ${partnerId} and is_available = true and date >= current_date
        order by date
      `)) as unknown as any[]);
  }
}

@Controller('availability')
class AvailabilityController {
  constructor(private readonly svc: AvailabilityService) {}
  @UseGuards(JwtGuard) @Post() set(@CurrentUser() u: AuthUser, @Body() b: { date: string; minutes: number }) {
    return this.svc.set(u.id, b.date, b.minutes);
  }
  @Get() forPartner(@Query('partnerId') partnerId: string) { return this.svc.forPartner(partnerId); }
}

@Module({ controllers: [AvailabilityController], providers: [AvailabilityService] })
export class AvailabilityModule {}
