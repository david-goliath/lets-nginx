#!/bin/bash

# Validate environment variables

MISSING=""

if [ "${LE_DOMAIN}" == "" ]; then
  if  [  "${SSL_DOMAIN}" == "" ]; then
    MISSING="MISSING LE_DOMAIN or SSL_DOMAIN variable"
  fi 
fi

[ -z "${UPSTREAM}" ] && MISSING="${MISSING} UPSTREAM"

set -eo pipefail

# Default other parameters
SERVER=""
[ -n "${STAGING:-}" ] && SERVER="--server https://acme-staging.api.letsencrypt.org/directory"

[ -n "${LE_DOMAIN:-}" ] && [ -z "${EMAIL}" ] && MISSING="${MISSING} EMAIL"

if [ "${MISSING}" != "" ]; then
  echo "Missing required environment variables:" >&2
  echo " ${MISSING}" >&2
  exit 1
fi

# Generate strong DH parameters for nginx, if they don't already exist.
if [ ! -f /etc/ssl/dhparams.pem ]; then
  if [ -f /cache/dhparams.pem ]; then
    cp /cache/dhparams.pem /etc/ssl/dhparams.pem
  else
    openssl dhparam -out /etc/ssl/dhparams.pem 2048
   # Cache to a volume for next time?
    if [ -d /cache ]; then
     cp /etc/ssl/dhparams.pem /cache/dhparams.pem
    fi
  fi
fi

#create temp file storage
mkdir -p /var/cache/nginx
chown nginx:nginx /var/cache/nginx

mkdir -p /var/tmp/nginx
chown nginx:nginx /var/tmp/nginx

#create vhost directory
mkdir -p /etc/nginx/vhosts/

# Process the nginx.conf with raw values of $DOMAIN and $UPSTREAM to ensure backward-compatibility
  dest="/etc/nginx/nginx.conf"
  echo "Rendering template of nginx.conf"
  sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
      -e "s/\${UPSTREAM}/${UPSTREAM}/" \
/templates/nginx.conf > "$dest"

if [ "${SSL_DOMAIN}" != "" ]; then

 # Process templates
 letscmd=""
 dest="/etc/nginx/vhosts/$(basename "${SSL_DOMAIN}").conf"
 src="/templates/vhost.sample.conf"

 if [ -r /configs/"${SSL_DOMAIN}".conf ]; then
   echo "Manual configuration found for $t"
   src="/configs/${SSL_DOMAIN}.conf"
 fi

 echo "Rendering template $src in $dest"
 sed -e "s/\${DOMAIN}/${SSL_DOMAIN}/g" \
  	    -e "s/\${UPSTREAM}/${UPSTREAM}/" \
 	    -e "s/\${PATH}/${SSL_DOMAIN}/" \
	    "$src" > "$dest"

 if [ ! -n "${SSL_DOMAIN:-}" ]; then
   echo Ready
   # Launch nginx in the foreground
   /usr/sbin/nginx -g "daemon off;"
   exit 
 fi
fi
# Process LE SSL template

if [ "${LE_DOMAIN}" != "" ]; then

  letscmd=""
  dest="/etc/nginx/vhosts/$(basename "${LE_DOMAIN}").conf"
  src="/templates/vhost.le-ssl.sample.conf"

  if [ -r /configs/"${LE_DOMAIN}".conf ]; then
    echo "Manual configuration found for $t"
    src="/configs/${LE_DOMAIN}.conf"
  fi

  echo "Rendering template $src of $LE_DOMAIN in $dest"
  sed -e "s/\${DOMAIN}/${LE_DOMAIN}/g" \
      -e "s/\${UPSTREAM}/${UPSTREAM}/" \
      -e "s/\${PATH}/${LE_DOMAIN}/" \
      "$src" > "$dest"


#prepare the letsencrypt command arguments
  letscmd="$letscmd -d $LE_DOMAIN "

# Check if the SAN list has changed
 if [ ! -f /etc/letsencrypt/san_list ]; then
  cat <<EOF >/etc/letsencrypt/san_list
  "${LE_DOMAIN}"
EOF
   fresh=true
 else
   old_san=$(cat /etc/letsencrypt/san_list)
   if [ "${LE_DOMAIN}" != "${old_san}" ]; then
     fresh=true
   else
     fresh=false
   fi
 fi

# Initial certificate request, but skip if cached
   if [ $fresh = true ]; then
     echo "The SAN list has changed, removing the old certificate and ask for a new one."
     rm -rf /etc/letsencrypt/{live,archive,keys,renewal}

    echo "certbot certonly "${letscmd}" \
     --standalone --text \
     "${SERVER}" \
     --email "${EMAIL}" --agree-tos \
     --expand " > /etc/nginx/lets

     echo "Running initial certificate request... "
     /bin/bash /etc/nginx/lets
   fi

#update the stored SAN list
 echo "${LE_DOMAIN}" > /etc/letsencrypt/san_list

#Create the renewal directory (containing well-known challenges)
 mkdir -p /etc/letsencrypt/webrootauth/

# Template a cronjob to reissue the certificate with the webroot authenticator
 echo "Creating a cron job to keep the certificate updated"
  cat <<EOF >/etc/periodic/monthly/reissue
#!/bin/sh

set -euo pipefail

# Certificate reissue
certbot certonly --force-renewal \
--webroot --text \
-w /etc/letsencrypt/webrootauth/ \
${letscmd} \
${SERVER} \
--email "${EMAIL}" --agree-tos \
--expand

# Reload nginx configuration to pick up the reissued certificates
/usr/sbin/nginx -s reload
EOF

 chmod +x /etc/periodic/monthly/reissue

# Kick off cron to reissue certificates as required
# Background the process and log to stderr
 /usr/sbin/crond -f -d 8 &

fi #LE_DOMAIN Section

echo Ready
# Launch nginx in the foreground
/usr/sbin/nginx -g "daemon off;"
