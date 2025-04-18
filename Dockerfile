FROM node:23-alpine

# Install nginx
RUN echo "http://dl-4.alpinelinux.org/alpine/v3.3/main" >> /etc/apk/repositories && \
    apk add --update nginx && \
    rm -rf /var/cache/apk/* && \
    chown -R nginx:www-data /var/lib/nginx

COPY ./nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
WORKDIR /app
COPY package.json .
RUN npm i
COPY . .
RUN npm remove toidentifier
CMD [ "sh", "scripts/start.sh"]