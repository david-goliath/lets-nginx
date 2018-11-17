FROM nginx:alpine
MAINTAINER Tarik Benammar <tarik@benammar.com>

#We need to install bash to easily handle arrays
# in the entrypoint.sh script
RUN apk add --update bash \
  certbot \
  openssl openssl-dev ca-certificates \
  fail2ban

RUN rm -rf /var/cache/apk/*

RUN rm -f /var/log/nginx/* && \
    touch /var/log/nginx/access.log && \
    touch /var/log/nginx/error.log

# fail2ban setup
RUN rm /etc/fail2ban/jail.d/*
COPY fail2ban/jail.local /etc/fail2ban/jail.d/
COPY fail2ban/filter.d/* /etc/fail2ban/filter.d/
RUN mkdir -p /var/run/fail2ban

# used for webroot reauth
RUN mkdir -p /etc/letsencrypt/webrootauth

COPY entrypoint.sh /opt/entrypoint.sh
ADD templates /templates

EXPOSE 80 443

ENTRYPOINT ["/opt/entrypoint.sh"]
