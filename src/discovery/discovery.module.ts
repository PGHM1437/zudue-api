import { Controller, Get, Injectable, Module, NotFoundException, Param, ParseUUIDPipe, Post, Query, UseGuards } from '@nestjs/common';
import { FeedQueryDto } from './discovery.dto';
import { ConfigService } from '@nestjs/config';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { toPublicMediaUrl } from '../storage/media-url.util';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/** partner_profiles.profile_id is uuid — anything else must never reach a query
 *  against it, or Postgres raises 22P02 and Nest renders it as a bare 500. */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

@Injectable()
class DiscoveryService {
  constructor(private readonly db: DatabaseService, private readonly config: ConfigService) {}

  /**
   * Home feed — suggested partners (featured → premium → rest). Public.
   * `q` searches display_name and bio; both are trigram-indexed (0046) so the
   * ILIKE stays index-backed rather than degrading to a seq scan. Name matches
   * outrank bio matches, then the usual featured/premium ordering applies.
   */
  /**
   * `offset`-paged, not cursor-paged: the ordering is a business ranking
   * (suggest_rank, then name), not an append-only timestamp, so there's no
   * natural monotonic cursor column to compare against — offset is the
   * pragmatic fit for a catalog this size. Previously hard-limited to 100
   * with no way to see past it at all, however many creators existed.
   */
  feed(category?: string, q?: string, limit = 100, offset = 0) {
    const term = q?.trim();
    return this.db.runAnon(async (tx) => {
      const like = term ? `%${term}%` : null;
      const rows = (await tx.execute(sql`
        select profile_id, display_name, bio, profile_image_path, is_premium, is_featured,
               min_call_price_paise, question_price_paise, shoutout_price_paise, categories, handle
        from public.vw_discover_partners
        where true
          ${category ? sql`and ${category} = any(categories)` : sql``}
          ${like ? sql`and (display_name ilike ${like} or bio ilike ${like})` : sql``}
        order by ${like ? sql`(display_name ilike ${like}) desc,` : sql``} suggest_rank, display_name
        limit ${limit} offset ${offset}
      `)) as unknown as any[];
      const publicBase = this.config.get<string>('R2_PUBLIC_MEDIA_URL');
      return rows.map((r) => ({ ...r, profile_image_path: toPublicMediaUrl(r.profile_image_path, publicBase) }));
    });
  }

  /** Resolve a shareable handle (from a creator's bio link) to their profile.
   *  Falls back to uuid so an older/handle-less link still works. */
  async byHandle(handle: string) {
    const id = await this.db.runAnon(async (tx) => {
      const rows = (await tx.execute(sql`
        select profile_id from public.partner_profiles where lower(handle) = lower(${handle}) limit 1
      `)) as unknown as any[];
      return rows[0]?.profile_id as string | undefined;
    });
    // The uuid fallback keeps older handle-less links working, but only when the
    // segment actually IS a uuid. Passing an unmatched handle straight through
    // cast it against a uuid column and threw 22P02 — so every typo'd or
    // retired /c/<handle> link 500'd instead of reading as "no such creator".
    const target = id ?? (UUID_RE.test(handle) ? handle : null);
    if (!target) throw new NotFoundException('PARTNER_NOT_FOUND');
    const profile = await this.partner(target);
    if (!profile) throw new NotFoundException('PARTNER_NOT_FOUND');
    return profile;
  }

  /** Public partner profile + live services. */
  partner(partnerId: string) {
    return this.db.runAnon(async (tx) => {
      const [profile] = (await tx.execute(sql`
        select pp.profile_id, pp.display_name, pp.bio, pp.profile_image_path,
               pp.is_premium, pp.is_featured, pp.status, pp.is_active, pp.vacation_mode,
               pp.languages
        from public.partner_profiles pp where pp.profile_id = ${partnerId}
      `)) as unknown as any[];
      if (profile) profile.profile_image_path = toPublicMediaUrl(profile.profile_image_path, this.config.get<string>('R2_PUBLIC_MEDIA_URL'));
      const services = (await tx.execute(sql`
        select service_type, duration, price_paise from public.partner_services
        where partner_id = ${partnerId} and is_active = true
      `)) as unknown as any[];
      const links = (await tx.execute(sql`
        select platform, url from public.partner_social_links
        where partner_id = ${partnerId} and is_approved = true
      `)) as unknown as any[];
      // Trust bar (REDESIGN_TODO.md #1 — was a client-side mock). Three
      // independent aggregates, each NULL/0 on an empty set rather than
      // erroring, so a brand-new partner just shows "0"/"—" honestly:
      //  - moments_count: completed calls + delivered shout-outs + answered
      //    questions — every kind of "delivered" service this partner has.
      //  - median_reply_minutes: median time from a question's opened_at to
      //    the partner's own first reply in that window (percentile_cont over
      //    zero rows is NULL, not an error).
      //  - fulfillment_rate_pct: COMPLETED_SUCCESSFUL bookings as a % of all
      //    of this partner's bookings ever (any status) — replaces the
      //    original mock's "% fans return" per product decision, since a
      //    booking-completion rate is what's actually computable today.
      const [trust] = (await tx.execute(sql`
        select
          (
            (select count(*) from public.calls where partner_id = ${partnerId} and attempt_status = 'COMPLETED_SUCCESSFUL')
            + (select count(*) from public.shout_out_requests where partner_id = ${partnerId} and status = 'VIDEO_DELIVERED_TO_FAN')
            + (select count(*) from public.conversation_windows w join public.conversations c on c.id = w.conversation_id
                where c.partner_id = ${partnerId} and w.status = 'ANSWERED')
          ) as moments_count,
          (
            select percentile_cont(0.5) within group (order by extract(epoch from (r.created_at - w.opened_at)) / 60)
            from public.conversation_windows w
            join public.conversations c on c.id = w.conversation_id
            join lateral (
              select m.created_at from public.messages m
              where m.window_id = w.id and m.sender = 'PARTNER'
              order by m.created_at asc limit 1
            ) r on true
            where c.partner_id = ${partnerId} and w.status = 'ANSWERED'
          ) as median_reply_minutes,
          (
            select case when count(*) = 0 then null
              else round(100.0 * count(*) filter (where status = 'COMPLETED_SUCCESSFUL') / count(*))
            end
            from public.bookings where partner_id = ${partnerId}
          ) as fulfillment_rate_pct
      `)) as unknown as any[];
      return profile ? { ...profile, services, socialLinks: links, ...trust } : null;
    });
  }

  /** Fan's saved creators. RLS (favourites_owner) scopes this to the caller. */
  favourites(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select d.profile_id, d.display_name, d.bio, d.profile_image_path, d.is_premium, d.is_featured,
               d.min_call_price_paise, d.question_price_paise, d.shoutout_price_paise, d.categories, d.handle,
               f.created_at as favourited_at
        from public.favourites f
        join public.vw_discover_partners d on d.profile_id = f.partner_id
        where f.fan_id = ${userId}
        order by f.created_at desc
      `)) as unknown as any[];
      const publicBase = this.config.get<string>('R2_PUBLIC_MEDIA_URL');
      return rows.map((r) => ({ ...r, profile_image_path: toPublicMediaUrl(r.profile_image_path, publicBase) }));
    });
  }

  toggleFavourite(userId: string, partnerId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_toggle_favourite', [partnerId]));
  }

  /**
   * "Tell me when this creator is bookable again." Distinct from a favourite:
   * this is a one-shot subscription that clears itself once the creator
   * returns (rpc_notify_waitlist flips WAITING -> NOTIFIED and pushes a
   * notification). A fan reaches an unavailable creator via a bio link or
   * their saved list — discovery already filters them out.
   */
  joinWaitlist(userId: string, partnerId: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_join_waitlist', [userId, partnerId]));
  }

  /** Whether the caller is already waiting, so the button reflects reality. */
  waitlistStatus(userId: string, partnerId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select status from public.waitlist
        where fan_id = ${userId} and partner_id = ${partnerId} limit 1
      `)) as unknown as any[];
      return { waiting: rows[0]?.status === 'WAITING' };
    });
  }

  /** Which of these partners the caller has favourited — one round trip so the
   *  feed can render filled/outlined hearts without N calls. */
  myFavouriteIds(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select partner_id from public.favourites where fan_id = ${userId}
      `)) as unknown as any[];
      return rows.map((r) => r.partner_id as string);
    });
  }

  categories() {
    return this.db.runAnon(async (tx) =>
      (await tx.execute(sql`select slug, name from public.categories order by sort_order`)) as unknown as any[]);
  }
}

@Controller('discover')
class DiscoveryController {
  constructor(private readonly svc: DiscoveryService) {}

  @Get() feed(@Query() q: FeedQueryDto) { return this.svc.feed(q.category, q.q, q.limit, q.offset); }
  @Get('categories') categories() { return this.svc.categories(); }
  // Static segments must precede the :id catch-all or /discover/favourites
  // would be parsed as a partner id.
  @UseGuards(JwtGuard) @Get('favourites') favourites(@CurrentUser() u: AuthUser) { return this.svc.favourites(u.id); }
  @UseGuards(JwtGuard) @Get('favourites/ids') favIds(@CurrentUser() u: AuthUser) { return this.svc.myFavouriteIds(u.id); }
  // ParseUUIDPipe on every param that lands in a uuid column: without it a
  // malformed id reached Postgres, raised 22P02 and surfaced as a bare 500.
  // `:handle` is deliberately exempt — it is free-form text by design.
  @UseGuards(JwtGuard) @Post('favourites/:partnerId') toggleFav(@CurrentUser() u: AuthUser, @Param('partnerId', ParseUUIDPipe) id: string) {
    return this.svc.toggleFavourite(u.id, id);
  }
  @UseGuards(JwtGuard) @Post('waitlist/:partnerId') joinWaitlist(@CurrentUser() u: AuthUser, @Param('partnerId', ParseUUIDPipe) id: string) {
    return this.svc.joinWaitlist(u.id, id);
  }
  @UseGuards(JwtGuard) @Get('waitlist/:partnerId') waitlistStatus(@CurrentUser() u: AuthUser, @Param('partnerId', ParseUUIDPipe) id: string) {
    return this.svc.waitlistStatus(u.id, id);
  }
  @Get('handle/:handle') byHandle(@Param('handle') handle: string) { return this.svc.byHandle(handle); }
  @Get('partner/:id') async partner(@Param('id', ParseUUIDPipe) id: string) {
    const p = await this.svc.partner(id);
    if (!p) throw new NotFoundException('PARTNER_NOT_FOUND');
    return p;
  }
}

@Module({ controllers: [DiscoveryController], providers: [DiscoveryService] })
export class DiscoveryModule {}
