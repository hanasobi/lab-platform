#!/usr/bin/env bash
set -euo pipefail
umask 077

DIR=/var/backups/etcd
KEEP=30
STAMP=$(date +%Y%m%d-%H%M%S)
PKI=/etc/kubernetes/pki/etcd
ETCDCTL=(etcdctl --endpoints=https://127.0.0.1:2379
         --cacert="$PKI/ca.crt"
         --cert="$PKI/healthcheck-client.crt"
         --key="$PKI/healthcheck-client.key")

install -d -m 0700 "$DIR"

# Nach dem Einschalten braucht etcd einen Moment
for i in $(seq 1 30); do
  "${ETCDCTL[@]}" endpoint health >/dev/null 2>&1 && break
  if [ "$i" -eq 30 ]; then echo "etcd nicht erreichbar" >&2; exit 1; fi
  sleep 10
done

"${ETCDCTL[@]}" snapshot save "$DIR/etcd-$STAMP.db"
etcdutl snapshot status "$DIR/etcd-$STAMP.db" -w table
tar -czf "$DIR/pki-$STAMP.tar.gz" -C /etc/kubernetes pki

ls -1t "$DIR"/etcd-*.db     | tail -n +$((KEEP + 1)) | xargs -r rm -f
ls -1t "$DIR"/pki-*.tar.gz  | tail -n +$((KEEP + 1)) | xargs -r rm -f
