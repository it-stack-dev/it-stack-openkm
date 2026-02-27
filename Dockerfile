# Dockerfile — IT-Stack OPENKM wrapper
# Module 14 | Category: business | Phase: 3
# Base image: openkm/openkm-ce:latest

FROM openkm/openkm-ce:latest

# Labels
LABEL org.opencontainers.image.title="it-stack-openkm" \
      org.opencontainers.image.description="OpenKM document management system" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-openkm"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/openkm/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
