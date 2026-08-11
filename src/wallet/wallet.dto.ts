import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsPositive, Max, Min } from 'class-validator';

/**
 * Money in. `creditPaise` previously arrived as a bare `@Body('creditPaise')`
 * with no runtime check — a string, a float, or a negative slipped through to
 * WalletService's own guard at best, and into arithmetic before it at worst.
 * The service keeps its integer/positive assertion (other callers exist); this
 * rejects the obvious garbage at the edge with a clear 400.
 *
 * The ceiling here is a sanity bound, NOT the business limit — the real
 * per-transaction min/max come from platform_settings and are enforced in the
 * service, because operators change them without a deploy.
 */
export class CreateTopupDto {
  @Type(() => Number)
  @IsInt({ message: 'creditPaise must be an integer number of paise' })
  @IsPositive()
  @Max(100_000_000, { message: 'creditPaise is implausibly large' })
  creditPaise!: number;
}

export class HistoryQueryDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(200)
  limit?: number;
}
