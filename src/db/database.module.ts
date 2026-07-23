import { Global, Module, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from './database.service';

@Global()
@Module({
  providers: [
    {
      provide: DatabaseService,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        const databaseUrl = config.get<string>('DATABASE_URL');
        if (!databaseUrl) {
          const logger = new Logger('DatabaseModule');
          logger.error('DATABASE_URL not configured - API will not function. Set DATABASE_URL environment variable.');
          throw new Error('DATABASE_URL environment variable is required');
        }
        return new DatabaseService(databaseUrl);
      },
    },
  ],
  exports: [DatabaseService],
})
export class DatabaseModule {}
