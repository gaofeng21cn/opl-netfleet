FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts --no-audit
COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src
RUN npm run build && npm prune --omit=dev --ignore-scripts --no-audit

FROM node:22-bookworm-slim
ENV NODE_ENV=production PORT=8788
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
COPY --from=build /app/dist ./dist
COPY --from=build /app/web ./web
RUN install -d -o node -g node /data
USER node
EXPOSE 8788
CMD ["node", "dist/server.js"]
