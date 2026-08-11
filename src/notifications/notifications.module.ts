import { Controller, Get, Injectable, Module, Param, Post, Query, UseGuards } from '@nestjs/common';
import { Type } from 'class-transformer';
import { IsInt, IsISO8601, IsOptional, Max, Min } from 'class-validator';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/**
 * Cursor pagination, not offset: `before` is the `created_at` of the oldest
 * row the client already has, so a notification written between two page
 * fetches can't shift every later row and duplicate/skip an item the way an
 * OFFSET would. Omitting `before` behaves exactly as it did previously
 * (latest `limit`, default 100) — no client change is required to keep
 * working; passing it is opt-in "load more" for callers that want it.
 */
class ListNotificationsQuery {
  @IsOptional() @IsISO8601() before?: string;
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100) limit?: number;
}

@Injectable()
class NotificationsService {
  constructor(private readonly db: DatabaseService) {}

  list(userId: string, before?: string, limit = 100) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select id, event_type, title, message, is_read, created_at from public.notifications
        where recipient_id = ${userId}
          ${before ? sql`and created_at < ${before}` : sql``}
        order by created_at desc limit ${limit}
      `)) as unknown as any[]);
  }
  markRead(userId: string, id: string) {
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`update public.notifications set is_read = true, read_at = now() where id = ${id} and recipient_id = ${userId}`);
      return { success: true };
    });
  }
  markAll(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`update public.notifications set is_read = true, read_at = now() where recipient_id = ${userId} and is_read = false`);
      return { success: true };
    });
  }
}

@Controller('notifications')
class NotificationsController {
  constructor(private readonly svc: NotificationsService) {}
  @UseGuards(JwtGuard) @Get() list(@CurrentUser() u: AuthUser, @Query() q: ListNotificationsQuery) {
    return this.svc.list(u.id, q.before, q.limit);
  }
  @UseGuards(JwtGuard) @Post(':id/read') read(@CurrentUser() u: AuthUser, @Param('id') id: string) { return this.svc.markRead(u.id, id); }
  @UseGuards(JwtGuard) @Post('read-all') all(@CurrentUser() u: AuthUser) { return this.svc.markAll(u.id); }
}

@Module({ controllers: [NotificationsController], providers: [NotificationsService] })
export class NotificationsModule {}
