import { Controller, Get, Injectable, Module, Param, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

@Injectable()
class NotificationsService {
  constructor(private readonly db: DatabaseService) {}

  list(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select id, event_type, title, message, is_read, created_at from public.notifications
        where recipient_id = ${userId} order by created_at desc limit 100
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
  @UseGuards(JwtGuard) @Get() list(@CurrentUser() u: AuthUser) { return this.svc.list(u.id); }
  @UseGuards(JwtGuard) @Post(':id/read') read(@CurrentUser() u: AuthUser, @Param('id') id: string) { return this.svc.markRead(u.id, id); }
  @UseGuards(JwtGuard) @Post('read-all') all(@CurrentUser() u: AuthUser) { return this.svc.markAll(u.id); }
}

@Module({ controllers: [NotificationsController], providers: [NotificationsService] })
export class NotificationsModule {}
