import { Controller, Get, Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { DatabaseModule } from './db/database.module';
import { AuthModule } from './auth/auth.module';
import { PaymentsModule } from './payments/payments.module';
import { PushModule } from './push/push.module';
import { StorageModule } from './storage/storage.module';
import { WalletModule } from './wallet/wallet.module';
import { IdentityModule } from './identity/identity.module';
import { ReferralsModule } from './referrals/referrals.module';
import { DiscoveryModule } from './discovery/discovery.module';
import { CatalogModule } from './catalog/catalog.module';
import { AvailabilityModule } from './availability/availability.module';
import { CallsModule } from './calls/calls.module';
import { MessagingModule } from './messaging/messaging.module';
import { ShoutoutsModule } from './shoutouts/shoutouts.module';
import { EarningsModule } from './earnings/earnings.module';
import { NotificationsModule } from './notifications/notifications.module';
import { TrustModule } from './trust/trust.module';
import { JobsModule } from './jobs/jobs.module';
import { AdminDashboardModule } from './admin/admin-dashboard.module';
import { AdminPeopleModule } from './admin/admin-people.module';
import { AdminFinanceModule } from './admin/admin-finance.module';
import { AdminModerationModule } from './admin/admin-moderation.module';
import { AdminSettingsModule } from './admin/admin-settings.module';

@Controller()
class HealthController {
  @Get()
  health() {
    return { status: 'ok', service: 'zudue-api' };
  }
}

@Module({
  controllers: [HealthController],
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    DatabaseModule,
    AuthModule,
    PaymentsModule,
    PushModule,
    StorageModule,
    // domains
    IdentityModule,
    ReferralsModule,
    DiscoveryModule,
    CatalogModule,
    AvailabilityModule,
    WalletModule,
    CallsModule,
    MessagingModule,
    ShoutoutsModule,
    EarningsModule,
    NotificationsModule,
    TrustModule,
    // admin (web panel — no RPCs beyond what's certified in the migrations)
    AdminDashboardModule,
    AdminPeopleModule,
    AdminFinanceModule,
    AdminModerationModule,
    AdminSettingsModule,
    // background
    JobsModule,
  ],
})
export class AppModule {}
