#!/bin/bash
set -euox pipefail

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

POSTGRES_IP=192.168.200.2
FDO_MANUFACTURING_ADDRESS=192.168.200.50
FDO_OWNER_ONBOARDING_ADDRESS=192.168.200.51
FDO_RENDEZVOUS_ADDRESS=192.168.200.52

POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=foobar
POSTGRES_DB=postgres

# Prepare stage repo network
greenprint "🔧 Prepare stage repo network"
sudo podman network inspect edge >/dev/null 2>&1 || sudo podman network create --driver=bridge --subnet=192.168.200.0/24 --gateway=192.168.200.254 edge

# Build FDO and clients container image
greenprint "🔧 Build FDO and clients container image"
sudo buildah build -f contrib/containers/build -t fdo-build:latest .
sudo buildah build -f contrib/containers/manufacturing-server --build-arg BUILDID=latest -t manufacturing-server:latest .
sudo buildah build -f contrib/containers/rendezvous-server --build-arg BUILDID=latest -t rendezvous-server:latest .
sudo buildah build -f contrib/containers/owner-onboarding-server --build-arg BUILDID=latest -t owner-onboarding-server:latest .
sudo buildah build -f contrib/containers/aio --build-arg BUILDID=latest -t aio:latest .
sudo buildah build -f test/files/clients --build-arg BUILDID=latest -t clients:latest .
sudo buildah images

##########################################################
##
## Prepare FDO containers
##
##########################################################
greenprint "🔧 Generate FDO key and configuration files"
mkdir aio
podman run -v "$PWD"/aio/:/aio:z \
  "localhost/aio:latest" \
  aio --directory aio generate-configs-and-keys --contact-hostname "$FDO_MANUFACTURING_ADDRESS"

# Prepare FDO config files
greenprint "🔧 Prepare FDO key and configuration files for FDO containers"
cp -r aio/keys fdo/
rm -f aio

# Set servers store driver to postgres
greenprint "🔧 Set servers store driver to postgres"
sudo pip3 install yq
/usr/local/bin/yq -iy '.service_info.diskencryption_clevis |= [{disk_label: "/dev/vda4", reencrypt: true, binding: {pin: "tpm2", config: "{}"}}]' fdo/serviceinfo-api-server.yml

# Prepare postgres db init sql script
greenprint "🔧 Prepare postgres db init sql script"
mkdir -p initdb
cp migrations_manufacturing_server_postgres/2023-10-03-152801_create_db/up.sql initdb/manufacturing.sql
cp migrations_owner_onboarding_server_postgres/2023-10-03-152801_create_db/up.sql initdb/owner-onboarding.sql
cp migrations_rendezvous_server_postgres/2023-10-03-152801_create_db/up.sql initdb/rendezvous.sql

greenprint "🔧 Starting postgres"
sudo podman run -d \
  --ip "$POSTGRES_IP" \
  --name postgres \
  --network edge \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -v "$PWD"/initdb/:/docker-entrypoint-initdb.d/:z \
  "quay.io/xiaofwan/postgres"

greenprint "🔧 Starting fdo manufacture server"
sudo podman run -d \
  --ip "$FDO_MANUFACTURING_ADDRESS" \
  --name manufacture-server \
  --network edge \
  -v "$PWD"/fdo/:/etc/fdo/:z \
  -p 8080:8080 \
  -e POSTGRES_MANUFACTURER_DATABASE_URL="postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}/${POSTGRES_DB}" \
  "localhost/manufacturing-server:latest"

greenprint "🔧 Starting fdo owner onboarding server"
sudo podman run -d \
  --ip "$FDO_OWNER_ONBOARDING_ADDRESS" \
  --name owner-onboarding-server \
  --network edge \
  -v "$PWD"/fdo/:/etc/fdo/:z \
  -p 8081:8081 \
  -e POSTGRES_OWNER_DATABASE_URL="postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}/${POSTGRES_DB}" \
  "localhost/owner-onboarding-server:latest"

greenprint "🔧 Starting fdo rendezvous server"
sudo podman run -d \
  --ip "$FDO_RENDEZVOUS_ADDRESS" \
  --name rendezvous-server \
  --network edge \
  -v "$PWD"/fdo/:/etc/fdo/:z \
  -p 8082:8082 \
  -e POSTGRES_RENDEZVOUS_DATABASE_URL="postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@${POSTGRES_IP}/${POSTGRES_DB}" \
  "localhost/rendezvous-server:latest"

# Wait for fdo containers to be up and running
until [ "$(curl -X POST http://${FDO_MANUFACTURING_ADDRESS}:8080/ping)" == "pong" ]; do
    sleep 1;
done;

until [ "$(curl -X POST http://${FDO_OWNER_ONBOARDING_ADDRESS}:8081/ping)" == "pong" ]; do
    sleep 1;
done;

until [ "$(curl -X POST http://${FDO_RENDEZVOUS_ADDRESS}:8082/ping)" == "pong" ]; do
    sleep 1;
done;

rm -rf initdb
exit 0
