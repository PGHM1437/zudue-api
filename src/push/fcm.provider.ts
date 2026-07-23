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

  /** Data-only high-priority send to many tokens. Returns dead tokens. */
  async sendData(tokens: string[], data: Record<string, string>, ttlSeconds = 45): Promise<string[]> {
    if (!this.enabled || tokens.length === 0) return [];
    const access = await this.jwt!.getAccessToken();
    const bearer = access.token;
    const dead: string[] = [];

    await Promise.all(tokens.map(async (token) => {
      try {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: {
              token,
              data,
              android: { priority: 'high', ttl: `${ttlSeconds}s`, direct_boot_ok: true },
              apns: { headers: { 'apns-priority': '10', 'apns-push-type': 'voip' } },
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
}
