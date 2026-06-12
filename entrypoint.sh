#!/bin/bash
# Prevent script from failing on minor errors during setup
set -e

# --- 1. Validate environment variables ---
MISSING=""
if [ -z "${LE_DOMAIN}" ] && [ -z "${SSL_DOMAIN}" ]; then
    MISSING="MISSING LE_DOMAIN or SSL_DOMAIN variable"
fi

[ -z "${UPSTREAM}" ] && MISSING="${MISSING} UPSTREAM"

# Default other parameters
SERVER=""
[ -n "${STAGING:-}" ] && SERVER="--server https://acme-staging.api.letsencrypt.org/directory"
[ -n "${LE_DOMAIN:-}" ] && [ -z "${EMAIL}" ] && MISSING="${MISSING} EMAIL"

if [ -n "${MISSING}" ]; then
    echo "Error: ${MISSING}" >&2
    exit 1
fi

# --- 2. Prepare Filesystem & Logs ---
# Fail2Ban will CRASH if these files don't exist on start
mkdir -p /var/log/nginx /var/run/fail2ban /etc/nginx/vhosts /etc/letsencrypt/webrootauth
touch /var/log/nginx/access.log /var/log/nginx/error.log
rm -f /var/run/fail2ban/fail2ban.sock # Clean up stale sockets from previous crashes

# Process domains into array
IFS=';' read -r -a DOMAINSARRAY <<< "${LE_DOMAIN}"
echo "Configuring for domains: ${DOMAINSARRAY[*]}"

# --- 3. Diffie-Hellman Parameters ---
if [ ! -f /etc/ssl/dhparams.pem ]; then
    if [ -f /cache/dhparams.pem ]; then
        cp /cache/dhparams.pem /etc/ssl/dhparams.pem
    else
        echo "Generating DH parameters (2048 bit)... this may take a moment."
        openssl dhparam -out /etc/ssl/dhparams.pem 2048
        [ -d /cache ] && cp /etc/ssl/dhparams.pem /cache/dhparams.pem
    fi
fi

# --- 4. Template Rendering ---
echo "Rendering nginx.conf"
sed -e "s/\${DOMAIN}/${DOMAIN}/g" -e "s/\${UPSTREAM}/${UPSTREAM}/" /templates/nginx.conf > /etc/nginx/nginx.conf

# Render SSL vhosts
if [ -n "${SSL_DOMAIN}" ]; then
    dest="/etc/nginx/vhosts/$(basename "${SSL_DOMAIN}").conf"
    src="/templates/vhost.sample.conf"
    [ -r "/configs/${SSL_DOMAIN}.conf" ] && src="/configs/${SSL_DOMAIN}.conf"
    
    sed -e "s/\${DOMAIN}/${SSL_DOMAIN}/g" -e "s/\${UPSTREAM}/${UPSTREAM}/" -e "s/\${PATH}/${SSL_DOMAIN}/" "$src" > "$dest"
fi

# --- 5. Let's Encrypt Logic ---
if [ -n "${LE_DOMAIN}" ]; then
    letscmd=""
    for t in "${DOMAINSARRAY[@]}"; do
        dest="/etc/nginx/vhosts/$(basename "${t}").conf"
        src="/templates/vhost.le-ssl.sample.conf"
        [ -r "/configs/${t}.conf" ] && src="/configs/${t}.conf"
        
        sed -e "s/\${DOMAIN}/${t}/g" -e "s/\${UPSTREAM}/${UPSTREAM}/" -e "s/\${PATH}/${DOMAINSARRAY[0]}/" "$src" > "$dest"
        letscmd="$letscmd -d $t"
    done

    # Check for SAN changes
    fresh=false
    if [ ! -f /etc/letsencrypt/san_list ] || [ "$(cat /etc/letsencrypt/san_list)" != "${LE_DOMAIN}" ]; then
        echo "SAN list changed or new install. Resetting certs."
        rm -rf /etc/letsencrypt/{live,archive,keys,renewal}
        fresh=true
    fi

    if [ "$fresh" = true ]; then
        echo "Requesting initial certificates..."
        certbot certonly $letscmd --standalone --non-interactive --agree-tos --email "${EMAIL}" ${SERVER} --expand
        echo "${LE_DOMAIN}" > /etc/letsencrypt/san_list
    fi

    # Update cli.ini (Removed the expired DST Root CA X3 reference)
    echo "preferred-chain = ISRG Root X1" > /etc/letsencrypt/cli.ini

    # Setup Renewal Cron
    cat <<EOF > /etc/periodic/monthly/reissue
#!/bin/bash
certbot renew --webroot -w /etc/letsencrypt/webrootauth/ --post-hook "nginx -s reload"
EOF
    chmod +x /etc/periodic/monthly/reissue
    /usr/sbin/crond -b # Start cron in background
fi

# --- 6. Launch Services ---
echo "Starting Fail2Ban..."
# -b starts in background, -x ensures it cleans up previous server remains
fail2ban-server -b -x

echo "Starting Nginx..."
exec nginx -g "daemon off;"
