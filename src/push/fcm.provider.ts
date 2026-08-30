import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JWT } from 'google-auth-library';

/**
 * FCM HTTP v1. For CALL RINGS we send a DATA-ONLY, priority=high message so the
 * client's background handler ALWAYS runs (even app-killed) and raises the
 * full-screen CallKit UI itself — a `notification` block would let the OS show a
 * tray item instead and skip the full-screen intent. High-priority data is also
 * what FCM allows to punch through Doze. Returns tokens FCM reports dead so the
 * caller can prune them.
 */
@Injectable()
export class FcmProvider {
  private readonly log = new Logger(FcmProvider.name);
  private jwt?: JWT;
  private projectId?: string;
  readonly enabled: boolean;

  constructor(config: ConfigService) {
    const b64 = config.get<string>('FCM_SERVICE_ACCOUNT_B64');
    this.projectId = config.get<string>('FCM_PROJECT_ID');
    if (b64) {
      try {
        const sa = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
        this.projectId ??= sa.project_id;
        this.jwt = new JWT({
          email: sa.client_email,
          key: sa.private_key,
          scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
        });
      } catch (e) {
        this.log.error('Invalid FCM_SERVICE_ACCOUNT_B64');
      }
    }
    this.enabled = !!this.jwt && !!this.projectId;
  }

  /**
   * Data-only high-priority send to many tokens. Returns dead tokens.
   *
   * `platform` is optional (older/backfilled rows may not have it) and
   * defaults to 'android'. Each message carries only the block matching ITS
   * platform — sending an `apns` block to an Android token is harmless (FCM
   * ignores blocks that don't match), but the two need genuinely different
   * headers, so branching is not cosmetic.
   *
   * iOS uses `apns-push-type: background`, NOT `voip`. A VoIP push requires a
   * PushKit registration and a separate VoIP APNs certificate; this app has
   * neither (ios/Runner/Info.plist deliberately does not declare the `voip`
   * background mode, and nothing registers with PushKit). Asserting
   * `apns-push-type: voip` without that certificate makes APNs REJECT the
   * push outright, so every iOS call ring would silently fail to arrive —
   * which is exactly what would have happened the moment a real iOS token
   * existed. `background` is what this app can actually deliver today.
   *
   * The trade-off is real and worth stating plainly: iOS throttles background
   * pushes and does not guarantee they wake a killed app, so killed-state
   * ringing stays unreliable on iOS until PushKit is implemented. That is a
   * platform constraint, not something a header can work around. Android is
   * unaffected — high-priority data still punches through Doze as before.
   *
   * Header rules are APNs': `background` REQUIRES `apns-priority: 5` (APNs
   * rejects priority 10 for that type) and a `content-available: 1` payload,
   * and `apns-expiration` is an absolute unix timestamp rather than the
   * relative TTL Android takes.
   */
  async sendData(
    tokens: Array<{ token: string; platform?: string }>,
    data: Record<string, string>,
    ttlSeconds = 45,
  ): Promise<string[]> {
    if (!this.enabled || tokens.length === 0) return [];
    const access = await this.jwt!.getAccessToken();
    const bearer = access.token;
    const dead: string[] = [];

    await Promise.all(tokens.map(async ({ token, platform }) => {
      const isIos = platform === 'ios';
      try {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: {
              token,
              data,
              ...(isIos
                ? {
                    apns: {
                      headers: {
                        'apns-priority': '5',
                        'apns-push-type': 'background',
                        'apns-expiration': `${Math.floor(Date.now() / 1000) + ttlSeconds}`,
                      },
                      payload: { aps: { 'content-available': 1 } },
                    },
                  }
                : { android: { priority: 'high', ttl: `${ttlSeconds}s`, direct_boot_ok: true } }),
            },
          }),
        });
        if (!res.ok) {
          const body = await res.text();
          if (res.status === 404 || body.includes('UNREGISTERED') || body.includes('INVALID_ARGUMENT')) dead.push(token);
          else this.log.warn(`FCM ${res.status}: ${body.slice(0, 200)}`);
        }
      } catch (e) {
        this.log.warn(`FCM send failed: ${(e as Error).message}`);
      }
    }));
    return dead;
  }

  /**
   * Visible push (a `notification` block, not data-only) for anything that
   * should show up in the OS tray on its own — the mobile client has no
   * handler for arbitrary data-only message types (only 'incoming_call' and
   * 'call_cancelled' are recognised; see push_service.dart), so a data-only
   * send here would silently show nothing. Normal priority: unlike a call
   * ring, this isn't racing Doze for a full-screen intent.
   */
  async sendNotification(
    tokens: Array<{ token: string; platform?: string }>,
    notification: { title: string; body: string },
    data?: Record<string, string>,
  ): Promise<string[]> {
    if (!this.enabled || tokens.length === 0) return [];
    const access = await this.jwt!.getAccessToken();
    const bearer = access.token;
    const dead: string[] = [];

    await Promise.all(tokens.map(async ({ token }) => {
      try {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: { token, notification, ...(data ? { data } : {}) },
          }),
        });
        if (!res.ok) {
          const body = await res.text();
          if (res.status === 404 || body.includes('UNREGISTERED') || body.includes('INVALID_ARGUMENT')) dead.push(token);
          else this.log.warn(`FCM ${res.status}: ${body.slice(0, 200)}`);
        }
      } catch (e) {
        this.log.warn(`FCM send failed: ${(e as Error).message}`);
      }
    }));
    return dead;
  }
}
