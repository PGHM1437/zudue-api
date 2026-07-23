import { Global, Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DatabaseService } from './database.service';

@Global()
@Module({
  providers: [
    {
      provide: DatabaseService,
      inject: [ConfigService],
      useFactory: (config: ConfigService) =>
        new DatabaseService(config.getOrThrow<string>('DATABASE_URL')),
    },
  ],
  exports: [DatabaseService],
})
export class DatabaseModule {}
