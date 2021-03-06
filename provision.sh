#!/usr/bin/env bash

# This script will provision all of the services. Each service will be setup in the following manner:
#
# 1. Migrations run,
# 2. Tenants—as in multi-tenancy—setup,
# 3. Service users and OAuth clients setup in LMS,
# 4. Static assets compiled/collected.


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Bring the databases online.
docker-compose up -d mysql mongo

# Ensure the MySQL server is online and usable
echo "Waiting for MySQL"
until docker exec -i edx.devstack.mysql mysql -uroot -se "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = 'root')" &> /dev/null
do
  printf "."
  sleep 1
done

# In the event of a fresh MySQL container, wait a few seconds for the server to restart
# This can be removed once https://github.com/docker-library/mysql/issues/245 is resolved.
sleep 20

echo -e "MySQL ready"

echo -e "${GREEN}Creating databases and users...${NC}"
docker exec -i edx.devstack.mysql mysql -uroot mysql < provision.sql
docker exec -i edx.devstack.mongo mongo < mongo-provision.js

# Bring the rest of the services online
docker-compose up -d

# Load database dumps for the largest databases to save time
./load-db.sh ecommerce
./load-db.sh edxapp
./load-db.sh edxapp_csmh

# Run edxapp migrations first since they are needed for the service users and OAuth clients
docker exec -t edx.devstack.edxapp  bash -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform && paver update_db --settings devstack_docker'

# Create a superuser for edxapp
docker exec -t edx.devstack.edxapp  bash -c 'source /edx/app/edxapp/edxapp_env && python /edx/app/edxapp/edx-platform/manage.py lms --settings=devstack_docker manage_user edx edx@example.com --superuser --staff'
docker exec -t edx.devstack.edxapp  bash -c 'source /edx/app/edxapp/edxapp_env && echo "from django.contrib.auth import get_user_model; User = get_user_model(); user = User.objects.get(username=\"edx\"); user.set_password(\"edx\"); user.save()" | python /edx/app/edxapp/edx-platform/manage.py lms shell  --settings=devstack_docker' &

# Enable the LMS-E-Commerce integration
docker exec -t edx.devstack.edxapp  bash -c 'source /edx/app/edxapp/edxapp_env && python /edx/app/edxapp/edx-platform/manage.py lms --settings=devstack_docker configure_commerce' &

# Create demo course and users
docker exec -t edx.devstack.edxapp  bash -c '/edx/app/edx_ansible/venvs/edx_ansible/bin/ansible-playbook /edx/app/edx_ansible/edx_ansible/playbooks/edx-east/demo.yml -v -c local -i "127.0.0.1," --extra-vars="COMMON_EDXAPP_SETTINGS=devstack_docker"' &

# We must fake an associative array for Bash 3 users
services=('credentials:18150' 'discovery:18381' 'ecommerce:18130')

for service in "${services[@]}"
do
    name=${service%%:*}
    port=${service#*:}

    echo -e "${GREEN}Installing requirements for ${name}...${NC}"
    docker exec -t edx.devstack.${name}  bash -c 'source /edx/app/$1/$1_env && cd /edx/app/$1/$1/ && make requirements' -- "$name"

    echo -e "${GREEN}Running migrations for ${name}...${NC}"
    docker exec -t edx.devstack.${name}  bash -c 'source /edx/app/$1/$1_env && cd /edx/app/$1/$1/ && make migrate' -- "$name"

    echo -e "${GREEN}Creating super-user for ${name}...${NC}"
	docker exec -t edx.devstack.${name}  bash -c 'source /edx/app/$1/$1_env && echo "from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser(\"edx\", \"edx@example.com\", \"edx\") if not User.objects.filter(username=\"edx\").exists() else None" | python /edx/app/$1/$1/manage.py shell' -- "$name" &

    echo -e "${GREEN}Creating service user and OAuth client for ${name}...${NC}"
    docker exec -t edx.devstack.edxapp  bash -c 'source /edx/app/edxapp/edxapp_env && python /edx/app/edxapp/edx-platform/manage.py lms --settings=devstack_docker manage_user $1_worker $1_worker@example.com --staff' -- "$name" &
    docker exec -t edx.devstack.edxapp  bash -c 'source /edx/app/edxapp/edxapp_env && python /edx/app/edxapp/edx-platform/manage.py lms --settings=devstack_docker create_oauth2_client "http://localhost:$2" "http://localhost:$2/complete/edx-oidc/" confidential --client_name $1 --client_id "$1-key" --client_secret "$1-secret" --trusted --logout_uri "http://localhost:$2/logout/" --username $1_worker' -- "$name" "$port" &
done


# Configure ecommerce
docker exec -t edx.devstack.ecommerce bash -c 'source /edx/app/ecommerce/ecommerce_env && python /edx/app/ecommerce/ecommerce/manage.py create_or_update_site --site-id=1 --site-domain=localhost:18130 --partner-code=edX --partner-name="Open edX" --lms-url-root=http://edx.devstack.edxapp:18000 --theme-scss-path=sass/themes/edx.scss --payment-processors=cybersource,paypal --client-id=ecommerce-key --client-secret=ecommerce-secret --from-email staff@example.com' &
docker exec -t edx.devstack.ecommerce bash -c 'source /edx/app/ecommerce/ecommerce_env && python /edx/app/ecommerce/ecommerce/manage.py oscar_populate_countries' &

# TODO Create discovery tenant with correct credentials (ECOM-6565)
docker exec -t edx.devstack.discovery bash -c 'source /edx/app/discovery/discovery_env && python /edx/app/discovery/discovery/manage.py create_or_update_partner --code edx --name edX --courses-api-url "http://edx.devstack.edxapp:18000/api/courses/v1/" --ecommerce-api-url "http://edx.devstack.ecommerce:18130/api/v2/" --organizations-api-url "http://edx.devstack.edxapp:18000/api/organizations/v0/" --oidc-url-root "http://edx.devstack.edxapp:18000/oauth2" --oidc-key discovery-key --oidc-secret discovery-secret' &

# TODO Create credentials tenant (ECOM-6566)

# Compile static assets last since they are absolutely necessary for all services. This will allow developers to get
# started if they do not care about static assets
for service in "${services[@]}"
do
    name=${service%%:*}

    echo -e "${GREEN}Compiling static assets for ${name}...${NC}"
    docker exec -t edx.devstack.${name}  bash -c 'source /edx/app/$1/$1_env && cd /edx/app/$1/$1/ && make static' -- "$name" &
done

# Save the longest for last...
docker exec -t edx.devstack.edxapp  bash -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform && paver update_assets --settings devstack_docker'

# Wait for all of the forked processes to exit
wait

echo -e "${GREEN}Provisioning complete!${NC}"
