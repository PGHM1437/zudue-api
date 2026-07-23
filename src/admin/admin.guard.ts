import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';

/**
 * Baseline "is this caller an admin at all" gate — checked here so a
 * non-admin never even reaches a controller method. Fine-grained RBAC tiers
 * (SUPER_ADMIN/FINANCE/SUPPORT/MODERATOR via admin_profiles.admin_role) are
 * NOT re-implemented here: every admin RPC already calls assert_admin_role()
 * itself and rejects with a clear error. Duplicating that split-brain in two
 * places is how they drift; the DB stays the single source of truth.
 */
@Injectable()
export class AdminGuard implements CanActivate {
  constructor(private readonly db: DatabaseService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest();
    const userId = req.user?.id;
    if (!userId) throw new ForbiddenException('NOT_AUTHENTICATED');

    const isAdmin = await this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`select role from public.profiles where id = ${userId}`)) as unknown as Array<{ role: string }>;
      return rows[0]?.role === 'ADMIN';
    });
    if (!isAdmin) throw new ForbiddenException('ADMIN_ONLY');
    return true;
  }
}
