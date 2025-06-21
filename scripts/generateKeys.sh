#!/bin/bash

echo Generating keys for Authentik...
echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')" >> .env

echo Generating keys for Unami...
echo "HASH_SALT=$(openssl rand -base64 64 | tr -d '\n')" >> .env
echo "UNAMI_APP_SECRET=$(openssl rand 30 | openssl base64 -A | tr -d '\n')" >> .env 
