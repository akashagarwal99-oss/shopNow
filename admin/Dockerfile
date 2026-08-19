# admin/Dockerfile
############################
# Stage 1: Build
############################
FROM node:18-alpine AS builder
WORKDIR /app

RUN apk add --no-cache python3 make g++ || true

COPY package*.json ./
RUN npm ci --no-audit --prefer-offline

COPY . .
# Build argument for dynamic user path
ARG USER_NAME=akash
ENV PUBLIC_URL=/${USER_NAME}-admin
ENV REACT_APP_API_BASE_URL=/${USER_NAME}-admin/api
RUN npm run build

############################
# Stage 2: Runtime (nginx)
############################
FROM nginx:1.24-alpine

# Copy admin-specific nginx config included in the admin folder
COPY nginx/default.conf /etc/nginx/conf.d/default.conf

# Copy built static admin app
COPY --from=builder /app/build /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- --no-check-certificate http://127.0.0.1/health || exit 1

CMD ["nginx", "-g", "daemon off;"]

