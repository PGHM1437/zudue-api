import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * OneSignal — a SECOND, independent delivery path. OneSignal's own infra often
 * gets through MIUI/ColorOS restrictions when raw FCM is throttled, so we fan
 * every call ring to both providers. The client dedupes on callId, so a device
 * that receives both rings only once.
 */
@Injectable()
export class OneSignalProvider {
  private readonly log = new Logger(OneSignalProvider.name);
  private readonly appId?: string;
  private readonly restKey?: string;
  private readonly callChannel: string;
  readonly enabled: boolean;

  constructor(config: ConfigService) {
    this.appId = config.get('ONESIGNAL_APP_ID');
    this.restKey = config.get('ONESIGNAL_REST_API_KEY');
    this.callChannel = config.get('PUSH_CALL_CHANNEL_ID') ?? 'zudue_calls';
    this.enabled = !!this.appId && !!this.restKey;
  }

  async sendCall(playerIds: string[], data: Record<string, string>, title: string, body: string) {
    if (!this.enabled || playerIds.length === 0) return;
    try {
      const res = await fetch('https://onesignal.com/api/v1/notifications', {
        method: 'POST',
        headers: { Authorization: `Basic ${this.restKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          app_id: this.appId,
          include_player_ids: playerIds,
          data,
          priority: 10,
          content_available: true,          // background data delivery
          android_channel_id: this.callChannel,
          android_visibility: 1,
          ttl: 45,
          headings: { en: title },
          contents: { en: body },
        }),
      });
      if (!res.ok) this.log.warn(`OneSignal ${res.status}: ${(await res.text()).slice(0, 200)}`);
    } catch (e) {
      this.log.warn(`OneSignal send failed: ${(e as Error).message}`);
    }
  }
}
