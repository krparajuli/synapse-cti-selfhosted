#!/bin/bash
REGISTRY="https://index.docker.io/v1/"
USERNAME="myuser"
PASSWORD="mypass"
EMAIL="myemail@example.com"
AUTH=$(echo -n "$USERNAME:$PASSWORD" | base64)

cat >docker-config.json <<EOF
{
  "auths": {
    "$REGISTRY": {
      "username": "$USERNAME",
      "password": "$PASSWORD",
      "email": "$EMAIL",
      "auth": "$AUTH"
    }
  }
}
EOF
