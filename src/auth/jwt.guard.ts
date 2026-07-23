import {
  CanActivate, ExecutionContext, Injectable, UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createRemoteJWKSet, jwtVerify, JWTPayload } from 'jose';

/**
 * Verifies the managed-auth (Supabase Auth / Clerk) access token against the
 * provider's JWKS. We RENT auth — the API only verifies; it never issues or
 * stores credentials. The verified subject (`sub`) becomes `app.user_id` for the
 * request, which is the only identity the DB trusts.
 *
 * Provider JWT algorithm/key rotation is absorbed here (JWKS), never in the DB —
 * exactly why the schema reads a GUC and never `auth.uid()`.
 */
@Injectable()
export class JwtGuard implements CanActivate {
  private readonly jwks: ReturnType<typeof createRemoteJWKSet>;
  private readonly issuer: string;
  private readonly audience: string;

  constructor(config: ConfigService) {
    this.jwks = createRemoteJWKSet(new URL(config.getOrThrow('AUTH_JWKS_URL')));
    this.issuer = config.getOrThrow('AUTH_ISSUER');
    this.audience = config.getOrThrow('AUTH_AUDIENCE');
  }

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req = ctx.switchToHttp().getRequest();
    const auth: string | undefined = req.headers['authorization'];
    if (!auth?.startsWith('Bearer ')) throw new UnauthorizedException('Missing bearer token');
    try {
      const { payload } = await jwtVerify(auth.slice(7), this.jwks, {
        issuer: this.issuer,
        audience: this.audience,
      });
      req.user = this.toUser(payload);
      return true;
    } catch {
      throw new UnauthorizedException('Invalid token');
    }
  }

  private toUser(p: JWTPayload) {
    if (!p.sub) throw new UnauthorizedException('Token has no subject');
    return { id: p.sub, email: (p as any).email as string | undefined };
  }
}
