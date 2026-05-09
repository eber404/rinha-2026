FROM alpine:3.19

RUN apk add --no-cache nginx

RUN echo 'server { listen 9999; location / { proxy_pass http://fraud-api-1:8080; } }' > /etc/nginx/http.d/default.conf && \
    echo 'stream { server { listen 9999; proxy_pass fraud-api-1:8080; } }' > /etc/nginx/conf.d/stream.conf

RUN rm -f /etc/nginx/http.d/default.conf

RUN echo 'daemon off; worker_processes 1;' > /etc/nginx/nginx.conf && \
    echo 'events { worker_connections 1024; }' >> /etc/nginx/nginx.conf && \
    echo 'stream { server { listen 9999; proxy_pass fraud-api-1:8080; } }' >> /etc/nginx/nginx.conf

EXPOSE 9999

CMD ["nginx"]