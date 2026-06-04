FROM nginx:alpine

LABEL maintainer="LeVanHai"
LABEL description="Xbrain x AWS Accelerator & Internship Program"

# Remove default nginx content
RUN rm -rf /usr/share/nginx/html/*

# Copy app files
COPY index.html  /usr/share/nginx/html/
COPY style.css   /usr/share/nginx/html/
COPY logo.jpg    /usr/share/nginx/html/
COPY intern.jpg  /usr/share/nginx/html/

# Custom nginx config: gzip + cache headers
RUN printf 'server {\n\
    listen 80;\n\
    server_name _;\n\
    root /usr/share/nginx/html;\n\
    index index.html;\n\
    gzip on;\n\
    gzip_types text/plain text/css application/javascript image/jpeg;\n\
    location / {\n\
        try_files $uri $uri/ /index.html;\n\
    }\n\
    add_header X-Served-By "K8s-on-AWS" always;\n\
    add_header X-Cluster  "kind-xbrain"  always;\n\
}\n' > /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q --spider http://localhost/ || exit 1
