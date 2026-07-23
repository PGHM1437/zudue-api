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
  const allowedOrigins = origins.length ? origins : true;
  
  app.enableCors({
    origin: (origin, callback) => {
      // Allow requests with no origin (like mobile apps or Postman)
      if (!origin) return callback(null, true);
      
      // In production with specified origins, check the origin
      if (Array.isArray(allowedOrigins)) {
        if (allowedOrigins.some(o => o === '*' || origin.startsWith(o))) {
          return callback(null, true);
        }
        return callback(new Error('Not allowed by CORS'));
      }
      
      // In development or when CORS_ORIGINS is not set, allow all
      callback(null, true);
    },
    credentials: true,
  });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));
  app.setGlobalPrefix('v1');
  const port = process.env.PORT ? Number(process.env.PORT) : 3000;
  await app.listen(port);
  new Logger('bootstrap').log(`Zudue API listening on :${port}/v1`);
}
bootstrap();
