import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { Logger, ValidationPipe } from '@nestjs/common';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, {
    rawBody: true, // needed for HMAC verification of the Razorpay webhook body
  });
  // Allowlist, not reflect-any. CORS_ORIGINS is a comma-separated list of the
  // admin panel + web origins; the mobile app is native and sends no Origin.
  // Falls back to permissive only in development.
  const origins = (process.env.CORS_ORIGINS ?? '').split(',').map((o) => o.trim()).filter(Boolean);
  app.enableCors({
    origin: origins.length ? origins : process.env.NODE_ENV === 'production' ? false : true,
    credentials: true,
  });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));
  app.setGlobalPrefix('v1');
  const port = process.env.PORT ? Number(process.env.PORT) : 3000;
  await app.listen(port);
  new Logger('bootstrap').log(`Zudue API listening on :${port}/v1`);
}
bootstrap();
