import { Controller, Get, Inject, Injectable, Logger, Module, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { HttpAdapterHost } from '@nestjs/core';
import type { Server } from 'node:http';
import { JwtGuard } from '../auth/jwt.guard';
import { PgNotifySource } from './pg-notify.source';
import { RealtimeGateway } from './realtime.gateway';
import { REALTIME_SOURCE, RealtimeEventSource } from './realtime.types';

/**
 * Nest lifecycle adapter for [RealtimeGateway]: finds the HTTP server once the
 * app is up, mounts the socket on it, and drains sockets on shutdown so a
 * deploy tells clients to reconnect instead of leaving them on a dead line.
 */
@Injectable()
export class RealtimeService implements OnApplicationBootstrap, OnModuleDestroy {
  private readonly log = new Logger('Realtime');
  private gateway?: RealtimeGateway;
  private statsTimer?: NodeJS.Timeout;

  constructor(
    private readonly adapterHost: HttpAdapterHost,
    private readonly auth: JwtGuard,
    private readonly config: ConfigService,
    @Inject(REALTIME_SOURCE) private readonly source: RealtimeEventSource,
  ) {}

  onApplicationBootstrap(): void {
    const server = this.adapterHost.httpAdapter?.getHttpServer() as Server | undefined;
    if (!server) {
      // Not fatal: the app runs exactly as it did before realtime existed.
      this.log.error('No HTTP server available; realtime gateway not started');
      return;
    }
    const enabled = this.config.get<boolean>('REALTIME_ENABLED') ?? true;
    this.gateway = new RealtimeGateway(this.auth, this.source, this.log, enabled);
    this.gateway.attach(server);
    if (enabled) {
      // One line every 5 minutes: enough to see load and delivery without a metrics stack.
      this.statsTimer = setInterval(() => this.log.log(`stats ${JSON.stringify(this.gateway?.stats())}`), 5 * 60_000);
      this.statsTimer.unref();
    }
  }

  async onModuleDestroy(): Promise<void> {
    clearInterval(this.statsTimer);
    await this.gateway?.destroy();
  }

  /** Aggregate only — never per-user data. */
  health() {
    const s = this.gateway?.stats();
    return { enabled: s?.enabled ?? false, healthy: s?.healthy ?? false };
  }
}

/** For load balancers / dashboards. Deliberately separate from the main health
 *  check: a realtime problem must never get a healthy API instance restarted. */
@Controller('realtime')
class RealtimeController {
  constructor(private readonly svc: RealtimeService) {}

  @Get('health')
  health() {
    return this.svc.health();
  }
}

@Module({
  controllers: [RealtimeController],
  providers: [
    {
      provide: REALTIME_SOURCE,
      inject: [ConfigService],
      // LISTEN needs a session-level connection; see env.ts. The fallback to
      // DATABASE_URL is only correct when that URL is not a transaction pooler,
      // and the source's boot probe reports it loudly when it is.
      useFactory: (config: ConfigService): RealtimeEventSource =>
        new PgNotifySource(
          config.get<string>('DATABASE_URL_LISTEN') ?? config.getOrThrow<string>('DATABASE_URL'),
          new Logger('RealtimeSource'),
        ),
    },
    RealtimeService,
  ],
})
export class RealtimeModule {}
