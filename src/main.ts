import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { Logger, ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AppModule } from './app.module';
import type { Env } from './config/env';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, {
    rawBody: true, // needed for HMAC verification of the Razorpay webhook body
  });
  // CORS - allow all origins for maximum compatibility
  // The API is secured by JWT verification, not CORS restrictions
  app.enableCors({
    origin: true, // Allow all origins
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'Accept'],
  });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));
  // Without this, Nest never invokes onModuleDestroy on SIGTERM, so every
  // deploy tore down the process with the postgres pool still open and the
  // BullMQ worker mid-job. DatabaseService and JobsService both implement the
  // hook already — nothing was calling it.
  app.enableShutdownHooks();
  app.setGlobalPrefix('v1');
  // Reads the value ConfigModule's `validate: loadEnv` already coerced and
  // checked at boot (config/env.ts: z.coerce.number().default(3000)) — a
  // non-numeric PORT now fails loudly during module init, before the app
  // ever reaches app.listen(), instead of silently becoming NaN here.
  const config = app.get(ConfigService<Env>);
  const port = config.getOrThrow('PORT', { infer: true }); // always present: schema has .default(3000)
  await app.listen(port);
  new Logger('bootstrap').log(`Zudue API listening on :${port}/v1`);
}
bootstrap();
