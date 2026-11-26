#!/bin/sh
set -eu

version="$(git rev-parse HEAD)"
broker="${PACT_BROKER_BASE_URL:?Pact Broker URL required}"
name="pact-provider-$(printf '%.12s' "$version")-$$"
image="local/pact-provider:$version"
docker build --build-arg "VERSION=$version" -t "$image" .
docker build --target pact-test -t "local/pact-verifier:$version" .
container="$(docker run -d --rm --name "$name" --network full-auto "$image")"
trap 'docker rm -f "$container" >/dev/null' EXIT
ready=false
for attempt in $(seq 1 30); do
  if docker exec "$container" python -c 'from urllib.request import urlopen; urlopen("http://127.0.0.1:8080/readyz")' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "Provider candidate did not become ready" >&2
  exit 1
fi

docker run --rm --network full-auto -e "PACT_BROKER_BASE_URL=$broker" \
  pactfoundation/pact-cli@sha256:328565c63fcd516c91ab9a3787231424e55ba22c05b082ab648dd67d841b47d9 \
  pact-broker create-or-update-version \
  --pacticipant demo-app --version "$version" --branch main
status="$(docker run --rm --network full-auto \
  -e "PACT_BROKER_BASE_URL=$broker" --entrypoint python \
  "local/pact-verifier:$version" -c '
import os
from urllib.error import HTTPError
from urllib.request import urlopen
url = os.environ["PACT_BROKER_BASE_URL"] + "/pacts/provider/demo-app/consumer/echo-app/latest"
try:
    with urlopen(url) as response:
        print(response.status)
except HTTPError as error:
    if error.code == 404:
        print("missing")
    else:
        raise
')"
if [ "$status" = missing ]; then
  echo "No Echo contract published yet; provider verification runs after Echo publishes one."
  exit 0
fi
docker run --rm --network full-auto \
  -e "PACT_BROKER_BASE_URL=$broker" \
  -e "PROVIDER_URL=http://$name:8080" \
  -e "PROVIDER_VERSION=$version" \
  "local/pact-verifier:$version"
