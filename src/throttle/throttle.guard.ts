import { CanActivate, ExecutionContext, HttpException, HttpStatus, Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Reflector } from '@nestjs/core';
import IORedis from 'ioredis';
import { SetMetadata } from '@nestjs/common';

/**
 * Per-route rate limiting. There is no `@nestjs/throttler` dependency here —
 * this environment has no pnpm available to add and lock a new package
 * correctly, so this reuses `ioredis` (already a real dependency via
 * JobsModule's BullMQ connection) instead of hand-writing a package.json
 * entry for a library that was never actually installed or verified.
 *
 * Fixed window counter (INCR + EXPIRE), keyed per IP per route. Simpler than
 * a sliding window; adequate for "stop obvious abuse", not precise enough for
 * billing-grade limiting — which this project doesn't need.
 *
 * Fails OPEN, matching every other optional-integration provider in this
 * codebase (FcmProvider, R2Provider, RazorpayProvider): if REDIS_URL isn't
 * configured, or Redis is briefly unreachable, requests are allowed through
 * rather than the API going down because a rate limiter couldn't reach its
 * store. A rate limiter that can 500 the whole API is worse than no limiter.
 */
export const RATE_LIMIT_KEY = 'rate_limit';
/** Decorator: `@RateLimit({ limit: 5, windowSeconds: 60 })` on a route or controller. */
export const RateLimit = (opts: { limit: number; windowSeconds: number }) => SetMetadata(RATE_LIMIT_KEY, opts);

@Injectable()
export class ThrottleGuard implements CanActivate {
  private static readonly log = new Logger(ThrottleGuard.name);
  private static redis: IORedis | null | undefined; // undefined = not yet attempted, null = unavailable

  constructor(private readonly reflector: Reflector, private readonly config: ConfigService) {}

  private getRedis(): IORedis | null {
    if (ThrottleGuard.redis !== undefined) return ThrottleGuard.redis;
    const url = this.config.get<string>('REDIS_URL');
    if (!url) {
      ThrottleGuard.log.warn('REDIS_URL not configured — rate limiting disabled (fail-open)');
      ThrottleGuard.redis = null;
      return null;
    }
    const client = new IORedis(url, { maxRetriesPerRequest: 1, lazyConnect: false });
    client.on('error', (e) => ThrottleGuard.log.warn(`redis error (rate limiting degraded): ${e.message}`));
    ThrottleGuard.redis = client;
    return client;
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const opts = this.reflector.getAllAndOverride<{ limit: number; windowSeconds: number }>(
      RATE_LIMIT_KEY,
      [context.getHandler(), context.getClass()],
    ) ?? { limit: 120, windowSeconds: 60 }; // global default: generous, just stops obvious abuse

    const redis = this.getRedis();
    if (!redis) return true; // fail open — see class doc comment

    const req = context.switchToHttp().getRequest();
    const ip = (req.headers['x-forwarded-for'] as string)?.split(',')[0]?.trim() || req.socket?.remoteAddress || 'unknown';
    const routeKey = `${req.method}:${req.route?.path ?? req.path}`;
    const key = `ratelimit:${routeKey}:${ip}`;

    try {
      const count = await redis.incr(key);
      if (count === 1) await redis.expire(key, opts.windowSeconds);
      if (count > opts.limit) {
        throw new HttpException(
          { error: 'RATE_LIMITED', message: `Too many requests — try again in a moment.` },
          HttpStatus.TOO_MANY_REQUESTS,
        );
      }
      return true;
    } catch (e) {
      if (e instanceof HttpException) throw e;
      ThrottleGuard.log.warn(`rate limit check failed (allowing request): ${(e as Error).message}`);
      return true; // fail open on any Redis error
    }
  }
}
