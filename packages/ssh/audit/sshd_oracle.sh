#!/bin/sh
# Real-sshd oracle: runs the system OpenSSH sshd(8) as the current user on 127.0.0.1:$SSHD_PORT and
# logs in with every certificate / authorized_keys case, printing sshd's verdict next to Pion's.
#
#   sh sshd_oracle.sh <oracle_pion_binary> <out_dir>
#
# Non-root sshd can only authenticate the user it runs as, so certificates are (re)issued at run time for
# principal $(id -un) by vectors/ca_ed (ssh-keygen for the ssh-keygen-expressible cases, `oracle craft`
# for duplicate / reordered options). Nothing is written outside <out_dir>.
set -eu
ORACLE=$1
OUT=$2/sshd
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PORT=${SSHD_PORT:-22999}
SSHD=${SSHD:-/usr/sbin/sshd}
ME=$(id -un)
rm -rf "$OUT" && mkdir -p "$OUT" && cd "$OUT"
cp "$AUDIT_DIR"/vectors/ca_ed "$AUDIT_DIR"/vectors/ca_ed.pub "$AUDIT_DIR"/vectors/user_ed "$AUDIT_DIR"/vectors/user_ed.pub .
chmod 600 ca_ed user_ed
ssh-keygen -q -t ed25519 -N '' -f hostkey
"$SSHD" -V 2>&1 | head -1 || true

W=20260101:20360101
ssh-keygen -q -s ca_ed -I ok -n "$ME" -V $W -z 1 -f /dev/null user_ed.pub 2>/dev/null; mv user_ed-cert.pub c_ok.pub
ssh-keygen -q -s ca_ed -I unknown_crit -n "$ME" -V $W -z 2 -O critical:evil@rt.example=x user_ed.pub; mv user_ed-cert.pub c_unknown_crit.pub
ssh-keygen -q -s ca_ed -I noprinc -V $W -z 3 user_ed.pub 2>/dev/null; mv user_ed-cert.pub c_noprinc.pub
ssh-keygen -q -s ca_ed -I srcaddr -n "$ME" -V $W -z 4 -O source-address=10.0.0.0/8 user_ed.pub; mv user_ed-cert.pub c_srcaddr.pub
for v in dupcrit unsorted_crit dupext unsorted_ext; do
  "$ORACLE" craft ca_ed "$(cat user_ed.pub)" $v "$ME" > c_$v.pub
done

cat > sshd_config <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $OUT/hostkey
PidFile $OUT/sshd.pid
TrustedUserCAKeys $OUT/ca_ed.pub
AuthorizedKeysFile $OUT/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel VERBOSE
PerSourcePenalties no
MaxStartups 100
CFG
: > authorized_keys
"$SSHD" -D -e -f sshd_config > sshd.log 2>&1 &
SSHD_PID=$!
trap 'kill $SSHD_PID 2>/dev/null || true' EXIT INT TERM
sleep 1

login() { # <identity> [cert] -> LOGIN (authenticated; a forced command may still run) / DENIED (ssh exit 255)
  if [ $# -ge 2 ]; then set -- "$1" -o CertificateFile="$OUT/$2"; else set -- "$1" -o CertificateFile=none; fi
  rc=0
  ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o IdentitiesOnly=yes -o ConnectTimeout=5 -i "$OUT/$@" -p "$PORT" "$ME@127.0.0.1" \
    'echo LOGIN_OK' >/dev/null 2>&1 </dev/null || rc=$?
  if [ "$rc" = 255 ]; then echo "DENIED"; else echo "LOGIN"; fi
}
hex() { od -An -v -tx1 | tr -d ' \n'; }
pion_cert() { # <cert file> -> Pion Certificate::verify(own CA, User, $ME, now=1800000000)
  printf 'x\tcertchk\t%s\t%s 1800000000\n' "$(cut -d' ' -f2 "$1" | base64 -d 2>/dev/null | hex)" "$ME" > one.tsv
  "$ORACLE" vectors one.tsv | cut -f2 | cut -c1-60
}
pion_ak() { # <authorized_keys file> -> number of keys Pion's parse_authorized_keys returns / ERR
  printf 'x\tak\t%s\n' "$(head -1 "$1" | tr -d '\n' | hex)" > one.tsv
  "$ORACLE" vectors one.tsv | cut -f2 | cut -c1-60
}

printf '\n%-22s %-8s %s\n' "certificate case" "sshd" "Pion Certificate::verify"
for c in ok unknown_crit noprinc srcaddr dupcrit unsorted_crit dupext unsorted_ext; do
  printf '%-22s %-8s %s\n' "$c" "$(login user_ed c_$c.pub)" "$(pion_cert c_$c.pub)"
done

printf '\n%-26s %-8s %s\n' "authorized_keys case" "sshd" "Pion parse_authorized_key_line (first line)"
K=$(cat user_ed.pub)
ak_case() { # <name> <line>
  printf '%s\n' "$2" > authorized_keys
  printf '%-26s %-8s %s\n' "$1" "$(login user_ed)" "$(pion_ak authorized_keys)"
}
ak_case plain "$K"
ak_case 'cmd="echo a\\"' 'command="echo a\\" '"$K"
ak_case unknown_option "frobnicate $K"
ak_case leading_comma ",no-pty $K"
ak_case dup_option "no-pty,no-pty $K"

printf '\n%s\n' "newline injection through encode_authorized_key(restrict,command=\"true\\n<attacker key> \") for user_ed:"
"$ORACLE" akinject "$K" "$(cat ca_ed.pub)" > authorized_keys
sed 's/^/  | /' authorized_keys | cut -c1-110
printf '  victim key  user_ed: sshd %s\n' "$(login user_ed)"
printf '  attacker key ca_ed: sshd %s   <- unrestricted login with a key the application never added\n' "$(login ca_ed)"

kill $SSHD_PID 2>/dev/null || true
printf '\nsshd log (refusal reasons):\n'
grep -E 'Refusing|not supported|lacks principal|invalid key option|permitted source|Accepted (publickey|certificate)' sshd.log \
  | sed -e 's/ signed by ED25519 CA SHA256:[^ ]*//' -e 's/ via .*//' -e 's/^/  /' | sort -u
