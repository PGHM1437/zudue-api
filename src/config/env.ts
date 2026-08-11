import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().default(3000),
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().url().optional(),
  AUTH_JWKS_URL: z.string().url(),
  AUTH_ISSUER: z.string(),
  AUTH_AUDIENCE: z.string().default('authenticated'),
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
