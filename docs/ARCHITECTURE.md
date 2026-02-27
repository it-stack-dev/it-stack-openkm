# Architecture — IT-Stack OPENKM

## Overview

OpenKM is the central document repository for the organization, providing versioned document storage and workflow automation.

## Role in IT-Stack

- **Category:** business
- **Phase:** 3
- **Server:** lab-biz1 (10.0.50.17)
- **Ports:** 8080 (HTTP)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → openkm → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
