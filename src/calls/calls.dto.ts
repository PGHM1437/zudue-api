import { IsIn, IsOptional, IsString, IsUUID, Matches, MaxLength } from 'class-validator';

/**
 * Request shapes for CallsController.
 *
 * These exist because the global ValidationPipe only validates DECORATED
 * CLASSES — the controllers previously typed their bodies as inline TS types
 * (or `any`), which carry no runtime metadata, so nothing was ever checked.
 * Every value here is cast to a Postgres enum/date/uuid at the bind site, so a
 * malformed value did not fail cleanly: it raised 22P02/22007 or "function
 * does not exist" and surfaced to the client as an opaque 500.
 *
 * Enum members mirror the DB exactly (verified against the live enums, not the
 * migration files): call_duration_options_enum and the missed-call subset of
 * call_status. Adding a duration in the DB means adding it here too.
 */

/** call_duration_options_enum — minutes, as the DB spells them. */
export const CALL_DURATIONS = ['1', '2', '3', '5', '7', '9', '12', '15'] as const;

export class BookCallDto {
  @IsUUID() partnerId!: string;

  /**
   * Cast to ::date in rpc_book_video_call.
   *
   * Deliberately accepts a trailing time component. GET /availability selects a
   * Postgres `date`, which postgres.js hydrates into a JS Date, so the client
   * receives "2026-08-28T00:00:00.000Z" and echoes that exact string back here
   * — a bare /^\d{4}-\d{2}-\d{2}$/ would 400 every genuine booking. Do not
   * tighten this without first changing what /availability emits.
   */
  @Matches(/^\d{4}-\d{2}-\d{2}([T ].*)?$/, { message: 'date must start with YYYY-MM-DD' })
  date!: string;

  @IsIn(CALL_DURATIONS as unknown as string[]) duration!: string;

  @IsOptional() @IsString() @MaxLength(500) note?: string;
  @IsOptional() @IsString() @MaxLength(64) promo?: string;
}

export class PreviewPriceDto {
  @IsUUID() partnerId!: string;
  @IsIn(CALL_DURATIONS as unknown as string[]) duration!: string;
  @IsOptional() @IsString() @MaxLength(64) promo?: string;
}

export class HeartbeatDto {
  @IsIn(['FAN', 'PARTNER']) actor!: 'FAN' | 'PARTNER';
}

/**
 * Only the missed/dropped subset is accepted. CallsService re-checks this
 * against the same list before binding it as a call_status — the DTO gives a
 * clean 400 at the edge, the service check keeps every other caller (jobs,
 * future endpoints) protected.
 */
export class MarkMissedDto {
  @IsIn(['MISSED_FAN_NO_JOIN', 'MISSED_FAN_DECLINED', 'DROPPED_TECHNICAL_ISSUE'])
  status!: string;
}
