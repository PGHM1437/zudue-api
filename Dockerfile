FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
RUN npm install -g pm2@5
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package*.json ./
COPY --from=build /app/migrations ./migrations
COPY --from=build /app/scripts ./scripts
EXPOSE 3000
# -i 2 = one worker per OCPU on the Always-Free Ampere shape (2 OCPU total).
# pm2-runtime keeps workers in the foreground (correct for a container's PID 1)
# and restarts a worker if it crashes, without needing a separate process manager.
CMD ["pm2-runtime", "start", "dist/main.js", "-i", "2", "--name", "zudue-api"]
