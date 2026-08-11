import { Controller, Get, Module } from '@nestjs/common';

/** Extracted from app.module.ts for consistency — every other controller in
 *  this codebase lives in its own module; this one was inline. */
@Controller()
class HealthController {
  @Get()
  health() {
    return { status: 'ok', service: 'zudue-api' };
  }
}

@Module({ controllers: [HealthController] })
export class HealthModule {}
