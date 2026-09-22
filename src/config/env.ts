import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().default(3000),
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().url().optional(),
  // Which scheduler drives the money/call lifecycle (settle, stalled-call
  // sweep, no-show refunds, DM-window expiry).
  //   'pgcron' (default) — pg_cron runs the job_* functions inside the DB
  //     (migration 0090). No always-on worker; keeps running when the web
  //     service idles. This is the fix for the "worker dies on idle" bug.
  //   'bullmq' — the legacy in-process BullMQ worker. Needs REDIS_URL AND a
  //     web service that never sleeps.
  JOBS_DRIVER: z.enum(['pgcron', 'bullmq']).default('pgcron'),
  // Realtime gateway (src/realtime): call-state events pushed over a WebSocket
  // instead of waiting on a poll.
  //
  // DATABASE_URL_LISTEN must be a SESSION-level connection to Postgres — the
  // direct URL, or Supabase's session-mode pooler (port 5432). It must NOT be a
  // transaction-mode pooler (Supabase port 6543, PgBouncer transaction mode):
  // LISTEN "succeeds" there but notifications are never delivered. Unset falls
  // back to DATABASE_URL, which is only right if that one is not a transaction
  // pooler; the gateway probes end-to-end at boot and refuses sockets (503)
  // rather than run silently deaf, so a wrong value is loud, not silent.
  DATABASE_URL_LISTEN: z.string().url().optional(),
  // Kill switch. 'false' stops the listener and rejects every upgrade; clients
  // fall back to the push + polling paths that still run underneath.
  REALTIME_ENABLED: z.enum(['true', 'false']).default('true').transform((v) => v === 'true'),
  AUTH_JWKS_URL: z.string().url(),
  AUTH_ISSUER: z.string(),
  AUTH_AUDIENCE: z.string().default('authenticated'),
  // GoTrue admin API — deletes the actual auth.users row (credentials) once
  // the deletion-request grace period elapses. Optional like every other
  // integration here: unset means the purge sweep anonymises profile data but
  // leaves the login intact, logged loudly rather than failing the sweep.
  SUPABASE_SERVICE_ROLE_KEY: z.string().optional(),
  RAZORPAY_KEY_ID: z.string().optional(),
  RAZORPAY_KEY_SECRET: z.string().optional(),
  RAZORPAY_WEBHOOK_SECRET: z.string().optional(),
  AGORA_APP_ID: z.string().optional(),
  AGORA_APP_CERTIFICATE: z.string().optional(),
  FCM_PROJECT_ID: z.string().optional(),
  FCM_SERVICE_ACCOUNT_B64: z.string().optional(),
  ONESIGNAL_APP_ID: z.string().optional(),
  ONESIGNAL_REST_API_KEY: z.string().optional(),
  PUSH_CALL_CHANNEL_ID: z.string().default('zudue_calls'),
  CORS_ORIGINS: z.string().optional(),
  R2_ACCOUNT_ID: z.string().optional(),
  R2_ACCESS_KEY_ID: z.string().optional(),
  R2_SECRET_ACCESS_KEY: z.string().optional(),
  R2_BUCKET_KYC: z.string().default('zudue-kyc'),
  R2_BUCKET_MEDIA: z.string().default('zudue-media'),
  R2_PUBLIC_MEDIA_URL: z.string().optional(),
  SENTRY_DSN: z.string().optional(),
});

export type Env = z.infer<typeof schema>;

/**
 * Also usable directly as `ConfigModule.forRoot({ validate: loadEnv })` — Nest
 * calls `validate(config)` with the merged env at boot, so this takes an
 * optional source and defaults to `process.env` for standalone use.
 *
 * This schema previously existed but was never imported anywhere: `main.ts`
 * read `process.env.PORT` directly, so a non-numeric PORT produced `NaN`
 * passed to `app.listen()` instead of a clear startup error naming the actual
 * misconfigured variable.
 */
export function loadEnv(config: Record<string, unknown> = process.env): Env {
  const parsed = schema.safeParse(config);
  if (!parsed.success) {
    // Fail fast and loud — a misconfigured money service must not boot.
    console.error('Invalid environment:', parsed.error.flatten().fieldErrors);
    throw new Error('Environment validation failed');
  }
  return parsed.data;
}
