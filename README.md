# SSL production container

SSL production container use for rails application.

Included :
- nginx
- fail2ban
- let's encrypt
- ssl certificate (without let's encrypt)

Based on docker lets-nginx :  https://github.com/smashwilson/lets-nginx

## fail2ban documentation

Logs are stored in container `/var/log/fail2ban.log`

Container needs to be run with `NET_ADMIN` capability (see: https://github.com/moby/moby/issues/33605#issuecomment-307361421 )

fail2ban nginx jail config is based on https://www.digitalocean.com/community/tutorials/how-to-protect-an-nginx-server-with-fail2ban-on-ubuntu-14-04

## lets-nginx documentation

ENV var :

```
EMAIL=me@email.com
  // email use for let's encrypt
LE_DOMAIN=mysite.com
  // domain to setup with let's encrypt
SSL_DOMAIN=mysite-custom-ssl.com
  // this domain will not use let's encrypt
  // but you have to provide the corresponding SSL certificate
  // the SSL certificates failed should be accessible at the following path in the container
  // certificate  : /etc/ssl/certs/${SSL_DOMAIN}/fullchain.crt
  // key : /etc/ssl/certs/${SSL_DOMAIN}/privkey.key
UPSTREAM=web:3000
  // stream the webcontainer on port 3000
STAGING=1
  //uses the Let's Encrypt staging server instead of the production one.
```

## example setup for docker-compose

```
  ssl:
    image: registry.domain.com:5000/${APP_NAME}_ssl
    restart: always
    environment:
      - EMAIL=email@domain.com
      - SSL_DOMAIN=${SSL_DOMAIN}
      - LE_DOMAIN=${LE_DOMAIN}
      - UPSTREAM=web:3000
    cap_add:
      - NET_ADMIN
    ports:
      - ${IP}:80:80
      - ${IP}:443:443
    volumes:
      - /etc/ssl/certs:/etc/ssl/certs
      - letsencrypt:/etc/letsencrypt
      - letsencrypt_backups:/var/lib/letsencrypt
      - dhparam_cache:/cache
    depends_on:
      - web
```

Notice that the volume defined are used to cache let's encrypt data and prevent 
a new generation of let's encrypt certificate at each container restart
