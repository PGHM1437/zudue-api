import { Body, Controller, Global, Module, Post, UseGuards } from '@nestjs/common';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';
import { FcmProvider } from './fcm.provider';
import { OneSignalProvider } from './onesignal.provider';
import { PushService, RegisterTokenDto } from './push.service';

@Controller('push')
class PushController {
  constructor(private readonly push: PushService) {}

  /** Called by the client after login and whenever the FCM/OneSignal id rotates. */
  @UseGuards(JwtGuard)
  @Post('register')
  register(@CurrentUser() user: AuthUser, @Body() dto: RegisterTokenDto) {
    return this.push.registerToken(user.id, dto);
  }
}

@Global()
@Module({
  controllers: [PushController],
  providers: [FcmProvider, OneSignalProvider, PushService],
  exports: [PushService],
})
export class PushModule {}
