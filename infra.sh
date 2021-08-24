#!/bin/bash

# If VM already exists, delete it
if [[ $(hcloud server list | grep webserver) ]]; then 
    hcloud server delete webserver
fi

# Create VM
server_ip=$(hcloud server create --type cx11 --image fedora-34 --name webserver --ssh-key ~/.ssh/gmail_rsa.pub | grep IPv4 | awk '{ print $2 }')

echo "Server created with ip: $server_ip"

# Fetch dns zone
dns_zone=$(curl -sX GET "https://api.cloudflare.com/client/v4/zones" \
                -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type:application/json" \
                | jq '.result[0] | .id' \
                | tr -d '"'
)

# Using dns zone, fetch dns record for 'test.tomasmota.dev'
dns_record_id=$(curl -sX GET "https://api.cloudflare.com/client/v4/zones/faf168b3fee15303eecb80fc186e1280/dns_records" \
                    -H "Authorization: Bearer $CF_TOKEN" \
                    -H "Content-Type:application/json" \
                    | jq '.result[] | select(.name == "test.tomasmota.dev") | .id' \
                    | tr -d '"'
)


if [[ ! -z $dns_record_id ]]; then
    echo "Dns record already exists, updating..."
    echo "zone: $dns_zone, id: $dns_record_id"

    result=$(curl -sX PUT "https://api.cloudflare.com/client/v4/zones/$dns_zone/dns_records/$dns_record_id" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type:application/json" \
        --data "{\"type\":\"A\",\"name\":\"test.tomasmota.dev\",\"content\":\"$server_ip\",\"ttl\":120}" \
        | jq '.success'
    )

    if [[ $result == 'true' ]]; then
        echo "Dns record updated"
    else
        echo "An error occured while updating dns records, exiting..."
        exit 1
    fi
else
    echo "Dns record does not yet exist, creating it now..."

    result=$(curl -sX POST "https://api.cloudflare.com/client/v4/zones/$dns_zone/dns_records/" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type:application/json" \
        --data "{\"type\":\"A\",\"name\":\"test.tomasmota.dev\",\"content\":\"$server_ip\",\"ttl\":120}" \
        | jq '.success'
    )

    if [[ $result == 'true' ]]; then
        echo "Dns record created"
    else
        echo "An error occured while creating dns record, exiting..."
        exit 1
    fi
fi

# Wait for server to boot up
echo "Sleeping for 20 seconds in order to let server start and dns records update..."
sleep 20

# Add fingerprint
ssh-keyscan test.tomasmota.dev >> ~/.ssh/known_hosts 2> /dev/null

# Install and start caddy
echo 'Installing Caddy...'
ssh root@test.tomasmota.dev 'dnf install -y caddy'
echo 'Starting Caddy...'
ssh root@test.tomasmota.dev 'caddy reverse-proxy --from test.tomasmota.dev --to localhost:8080' &

# Create go webserver
ssh root@test.tomasmota.dev 'cat <<EOF > main.go
package main

import (
    "fmt"
    "log"
    "net/http"
)

func handler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "Hi there, I love %s!", r.URL.Path[1:])
}

func main() {
    http.HandleFunc("/", handler)
    log.Fatal(http.ListenAndServe(":8080", nil))
}
EOF'

# Install and run go webserver
echo 'Installing go...'
ssh root@test.tomasmota.dev 'dnf install -y go'
echo 'Starting webserver'
ssh root@test.tomasmota.dev 'go run main.go' & sleep 5

check_server () {
    if [[ $(curl -Ls test.tomasmota.dev/success) = 'Hi there, I love success!' ]]; then 
        echo "Webserver is working!" 
        echo "Tearing down..."
        hcloud server delete webserver
        echo "Finished tear down, exiting"
        exit 0 
    fi
    echo "Server not working as expected"
    return 1
}

echo 'Smoke testing'
check_server
res=$?

# If we get here, it means something is wrong
echo 'Something went wrong, waiting a minute and trying again'
sleep 60

check_server

# If we get here, it means it is still not working
echo 'Still not working, exiting now'
exit 1
