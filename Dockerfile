FROM nginx:alpine

# Install additional tools for certificate generation and debugging
RUN apk add --no-cache openssl gettext bash curl

# Create required directories
RUN mkdir -p /etc/nginx/certs /var/log/nginx

# Copy nginx configuration template
COPY gateway/nginx/templates/ /etc/nginx/templates/
COPY gateway/nginx/snippets/ /etc/nginx/snippets/

# Copy certificate generation script
COPY gateway/scripts/gen-certs.sh /usr/local/bin/gen-certs.sh
RUN chmod +x /usr/local/bin/gen-certs.sh

# Generate self-signed certificates if they don't exist
RUN mkdir -p /etc/nginx/certs && \
    [ ! -f /etc/nginx/certs/fullchain.pem ] && \
    /usr/local/bin/gen-certs.sh || true

# Create entrypoint script that handles configuration and startup
RUN echo '#!/bin/sh\n\
set -e\n\
\n\
# Generate certs if missing\n\
if [ ! -f /etc/nginx/certs/fullchain.pem ]; then\n\
  echo "[gateway] generating self-signed certificate..."\n\
  /usr/local/bin/gen-certs.sh\n\
fi\n\
\n\
# Substitute environment variables and generate nginx config\n\
echo "[gateway] generating nginx configuration..."\n\
envsubst < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf\n\
\n\
# Validate configuration\n\
if ! nginx -t; then\n\
  echo "[gateway] nginx configuration is invalid" >&2\n\
  exit 1\n\
fi\n\
\n\
echo "[gateway] starting nginx..."\n\
\n\
# Start nginx in the foreground\n\
nginx -g "daemon off;"\n\
' > /usr/local/bin/entrypoint.sh && \
chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 8443

HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=10s \
  CMD curl -f -k https://localhost:8443/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
