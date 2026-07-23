import { BadRequestException, Body, Controller, Delete, Get, Module, Param, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

class CatalogService {
  constructor(private readonly db: DatabaseService) {}

  myServices(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select service_type, duration, price_paise, is_active
        from public.partner_services where partner_id = ${userId}
      `)) as unknown as any[]);
  }

  setService(userId: string, b: { type: string; duration?: string | null; pricePaise: number; active?: boolean }) {
    return this.db.runAs(userId, (tx) =>
      this.db.rpc(tx, 'rpc_partner_set_service', [userId, b.type, b.duration ?? null, b.pricePaise, b.active ?? true]));
  }

  /** Own links, including unapproved ones (RLS social_public_read allows the
   *  owner to see their own pending links; the public only sees approved). */
  mySocialLinks(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select id, platform, url, is_approved, created_at
        from public.partner_social_links where partner_id = ${userId}
        order by platform
      `)) as unknown as any[]);
  }

  private static readonly PLATFORMS = ['YOUTUBE', 'INSTAGRAM', 'FACEBOOK', 'TWITTER'];

  setSocialLink(userId: string, b: { platform: string; url: string }) {
    // platform lands in a social_platform_enum column, and there is a
    // UNIQUE (partner_id, platform) — a plain INSERT of a second link for the
    // same platform raised a constraint violation as a 500. Validate, then
    // upsert, and reset approval since the URL changed and must be re-reviewed.
    if (!CatalogService.PLATFORMS.includes(b?.platform)) {
      throw new BadRequestException(`platform must be one of ${CatalogService.PLATFORMS.join(', ')}`);
    }
    const url = b?.url?.trim() ?? '';
    if (!/^https?:\/\/.+\..+/i.test(url)) {
      throw new BadRequestException('url must be a valid http(s) link');
    }
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`
        insert into public.partner_social_links (partner_id, platform, url)
        values (${userId}, ${sql`${b.platform}::public.social_platform_enum`}, ${url})
        on conflict (partner_id, platform) do update
          set url = excluded.url, is_approved = false, approved_by_admin_id = null, updated_at = now()
      `);
      return { success: true };
    });
  }

  removeSocialLink(userId: string, id: string) {
    return this.db.runAs(userId, async (tx) => {
      await tx.execute(sql`delete from public.partner_social_links where id = ${id} and partner_id = ${userId}`);
      return { success: true };
    });
  }
}

@Controller('partner/catalog')
class CatalogController {
  constructor(private readonly svc: CatalogService) {}
  @UseGuards(JwtGuard) @Get('services') list(@CurrentUser() u: AuthUser) { return this.svc.myServices(u.id); }
  @UseGuards(JwtGuard) @Post('services') set(@CurrentUser() u: AuthUser, @Body() b: any) { return this.svc.setService(u.id, b); }
  @UseGuards(JwtGuard) @Get('social-links') listSocial(@CurrentUser() u: AuthUser) { return this.svc.mySocialLinks(u.id); }
  @UseGuards(JwtGuard) @Post('social-links') social(@CurrentUser() u: AuthUser, @Body() b: any) { return this.svc.setSocialLink(u.id, b); }
  @UseGuards(JwtGuard) @Delete('social-links/:id') delSocial(@CurrentUser() u: AuthUser, @Param('id') id: string) { return this.svc.removeSocialLink(u.id, id); }
}

@Module({ controllers: [CatalogController], providers: [CatalogService] })
export class CatalogModule {}
