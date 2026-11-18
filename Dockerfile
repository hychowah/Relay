FROM node:24.22.0-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json vite.config.ts ./
COPY shared ./shared
COPY server ./server
COPY web ./web
RUN npm run build && npm prune --omit=dev --no-audit --no-fund

FROM node:24.22.0-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production RELAY_HOST=0.0.0.0 RELAY_DATA_DIR=/data
RUN mkdir /data && chown node:node /data
COPY --from=build /app/package.json /app/package-lock.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/server ./server
COPY --from=build /app/shared ./shared
USER node
EXPOSE 3210
CMD ["node", "server/index.ts"]
