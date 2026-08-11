import { Global, Module, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { sql } from 'drizzle-orm';
import { DatabaseService } from './database.service';

/**
 * postgres.js connects lazily — constructing DatabaseService never throws on
 * an unreachable database, only the first real query does. On Render, that
 * first query was often the health check, which arrives shortly after boot;
 * if the DB takes longer to accept connections than the API container takes
 * to start (no ordering guarantee between them, unlike docker-compose's
 * `depends_on`), the deploy could look unhealthy for a transient reason.
 * This forces one real round trip — with bounded retries — before the module
 * resolves, so the app doesn't report itself ready until the DB actually is.
 */
async function waitForDatabase(db: DatabaseService, logger: Logger): Promise<void> {
  const maxAttempts = 6; // ~1+2+4+8+16+30s backoff, capped — bounded, not indefinite
  let delayMs = 1000;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await db.runAnon((tx) => tx.execute(sql`select 1`));
      if (attempt > 1) logger.log(`database reachable after ${attempt} attempts`);
      return;
    } catch (e) {
      if (attempt === maxAttempts) {
        logger.error(`database unreachable after ${maxAttempts} attempts: ${(e as Error).message}`);
        throw e;
      }
      logger.warn(`database not ready (attempt ${attempt}/${maxAttempts}): ${(e as Error).message} — retrying in ${delayMs}ms`);
      await new Promise((r) => setTimeout(r, delayMs));
      delayMs = Math.min(delayMs * 2, 30_000);
    }
  }
}

@Global()
@Module({
  providers: [
    {
      provide: DatabaseService,
      inject: [ConfigService],
      useFactory: async (config: ConfigService) => {
        const logger = new Logger('DatabaseModule');
        const databaseUrl = config.get<string>('DATABASE_URL');
        if (!databaseUrl) {
          logger.error('DATABASE_URL not configured - API will not function. Set DATABASE_URL environment variable.');
          throw new Error('DATABASE_URL environment variable is required');
        }
        const service = new DatabaseService(databaseUrl);
        await waitForDatabase(service, logger);
        return service;
      },
    },
  ],
  exports: [DatabaseService],
})
export class DatabaseModule {}
