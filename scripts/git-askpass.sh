#!/usr/bin/env bash
case "$1" in
  *Username*) printf 'demo\n' ;;
  *Password*) printf '%s\n' "$GITEA_ADMIN_PASSWORD" ;;
  *) exit 1 ;;
esac
