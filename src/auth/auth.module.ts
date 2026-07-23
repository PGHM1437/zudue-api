import { Global, Module } from '@nestjs/common';
import { JwtGuard } from './jwt.guard';

@Global()
@Module({
  providers: [JwtGuard],
  exports: [JwtGuard],
})
export class AuthModule {}
