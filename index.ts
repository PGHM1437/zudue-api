import { NestFactory, HttpAdapterHost } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { AppModule } from './dist/app.module';

// Keep the app instance in memory for subsequent requests
let app: any;

export default async function handler(req: any, res: any) {
  // Bootstrap our NestJS app on cold start
  if (!app) {
    app = await NestFactory.create(AppModule);
    
    app.enableCors({
      origin: true,
      credentials: true,
    });
    
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        transform: true,
      }),
    );
    
    app.setGlobalPrefix('v1');
    
    // This is important - initializes the app without listening
    await app.init();
  }

  const adapterHost = app.get(HttpAdapterHost);
  const httpAdapter = adapterHost.httpAdapter;
  const instance = httpAdapter.getInstance();
  instance(req, res);
}
