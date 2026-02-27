# Deployment Guide — IT-Stack OPENKM

## Prerequisites

- Ubuntu 24.04 Server on lab-biz1 (10.0.50.*)
- Docker 24+ and Docker Compose v2
- Phase 1 complete: FreeIPA, Keycloak, PostgreSQL, Redis, Traefik running
- DNS entry: openkm.it-stack.lab → lab-biz1

## Deployment Steps

### 1. Create Database (PostgreSQL on lab-db1)

```sql
CREATE USER openkm_user WITH PASSWORD 'CHANGE_ME';
CREATE DATABASE openkm_db OWNER openkm_user;
```

### 2. Configure Keycloak Client

Create OIDC client $Module in realm it-stack:
- Client ID: $Module
- Valid redirect URI: https://openkm.it-stack.lab/*
- Web origins: https://openkm.it-stack.lab

### 3. Configure Traefik

Add to Traefik dynamic config:
```yaml
http:
  routers:
    openkm:
      rule: Host(\$Module.it-stack.lab\)
      service: openkm
      tls: {}
  services:
    openkm:
      loadBalancer:
        servers:
          - url: http://lab-biz1:8080
```

### 4. Deploy

```bash
# Copy production compose to server
scp docker/docker-compose.production.yml admin@lab-biz1:~/

# Deploy
ssh admin@lab-biz1 'docker compose -f docker-compose.production.yml up -d'
```

### 5. Verify

```bash
curl -I https://openkm.it-stack.lab/health
```

## Environment Variables

| Variable | Description | Default |
|---------|-------------|---------|
| DB_HOST | PostgreSQL host | lab-db1 |
| DB_PORT | PostgreSQL port | 5432 |
| REDIS_HOST | Redis host | lab-db1 |
| KEYCLOAK_URL | Keycloak base URL | https://lab-id1:8443 |
| KEYCLOAK_REALM | Keycloak realm | it-stack |
