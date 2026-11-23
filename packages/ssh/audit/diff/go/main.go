// Red-team differential oracle for packages/ssh (Go golang.org/x/crypto/ssh v0.38.0 side).
//
//	oracle_go vectors <corpus.tsv>
//	oracle_go dos kh_star <n>
//	oracle_go bench_sshsig <sig_file> <msg_file> <n>
//
// Same input/output format as ../../oracle/src/main.pion:
// "<label>\t<kind>\t<hex>[\t<arg>]" -> "<label>\t<result>".
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

func pkDesc(pk ssh.PublicKey) string {
	return pk.Type() + " " + ssh.FingerprintSHA256(pk)
}

// keyAlg maps the Go type of a certificate to the plain key algorithm name.
func certDesc(c *ssh.Certificate) string {
	return fmt.Sprintf("%s type=%d serial=%d key=%s ca=%s np=%d nc=%d ne=%d",
		c.Type(), c.CertType, c.Serial, ssh.FingerprintSHA256(c.Key), ssh.FingerprintSHA256(c.SignatureKey),
		len(c.ValidPrincipals), len(c.CriticalOptions), len(c.Extensions))
}

// verbose (RT_VERBOSE=1) appends Go's error text to ERR results (used only for triage, never for diffing).
var verbose = os.Getenv("RT_VERBOSE") == "1"

func errOf(err error) string {
	if verbose && err != nil {
		return "ERR " + err.Error()
	}
	return "ERR"
}

func runOne(kind string, data []byte, arg string) string {
	switch kind {
	case "pk":
		pk, err := ssh.ParsePublicKey(data)
		if err != nil {
			return errOf(err)
		}
		if _, ok := pk.(*ssh.Certificate); ok {
			return "ERR" // Pion's parse_public_key_wire only accepts plain keys
		}
		return "OK " + pkDesc(pk)
	case "cert":
		pk, err := ssh.ParsePublicKey(data)
		if err != nil {
			return errOf(err)
		}
		c, ok := pk.(*ssh.Certificate)
		if !ok {
			return "ERR"
		}
		return "OK " + certDesc(c)
	case "ak":
		// ParseAuthorizedKey skips invalid lines; feed exactly one line.
		if bytes.IndexByte(data, '\n') >= 0 {
			return "ERR"
		}
		t := bytes.TrimSpace(data)
		if len(t) == 0 || t[0] == '#' {
			return "SKIP"
		}
		pk, _, opts, _, err := ssh.ParseAuthorizedKey(data)
		if err != nil {
			return errOf(err)
		}
		if c, ok := pk.(*ssh.Certificate); ok {
			return fmt.Sprintf("OK %s %s nopts=%d", c.Type(), ssh.FingerprintSHA256(c.Key), len(opts))
		}
		return fmt.Sprintf("OK %s nopts=%d", pkDesc(pk), len(opts))
	case "kh":
		if bytes.IndexByte(data, '\n') >= 0 {
			return "ERR"
		}
		t := bytes.TrimSpace(data)
		if len(t) == 0 || t[0] == '#' {
			return "SKIP"
		}
		marker, hosts, pk, _, _, err := ssh.ParseKnownHosts(data)
		if err != nil {
			return errOf(err)
		}
		if marker == "" {
			marker = "-"
		}
		return fmt.Sprintf("OK marker=%s nh=%d %s", marker, len(hosts), pkDesc(pk))
	case "certchk":
		pk, err := ssh.ParsePublicKey(data)
		if err != nil {
			return errOf(err)
		}
		c, ok := pk.(*ssh.Certificate)
		if !ok {
			return "ERR"
		}
		parts := strings.SplitN(arg, " ", 2)
		now := uint64(0)
		if len(parts) == 2 {
			now, _ = strconv.ParseUint(parts[1], 10, 64)
		}
		ca := c.SignatureKey.Marshal()
		chk := &ssh.CertChecker{
			// The OpenSSH-defined critical options (PROTOCOL.certkeys); source-address is
			// enforced later by CertChecker.Authenticate (not reachable without a conn).
			SupportedCriticalOptions: []string{"force-command", "verify-required"},
			IsUserAuthority:          func(a ssh.PublicKey) bool { return bytes.Equal(a.Marshal(), ca) },
			Clock:                    func() time.Time { return time.Unix(int64(now), 0) },
		}
		if c.CertType != ssh.UserCert {
			return "REJECT type"
		}
		if !chk.IsUserAuthority(c.SignatureKey) {
			return "REJECT ca"
		}
		if err := chk.CheckCert(parts[0], c); err != nil {
			return "REJECT " + err.Error()
		}
		return "OK"
	}
	return "BADKIND"
}

// dosKhStar: known_hosts line `("a*" * n) + "b" <key>` and a lookup of "a" * (4n), via knownhosts.New.
func dosKhStar(n int) {
	dir, _ := os.MkdirTemp("", "rt-ssh-kh")
	defer os.RemoveAll(dir)
	path := dir + "/known_hosts"
	line := strings.Repeat("a*", n) + "b ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHiojgVRI/bzT9/KdnJv9QzVjj6cRUQldIZUq76+c0ib\n"
	os.WriteFile(path, []byte(line), 0o600)
	cb, err := knownhosts.New(path)
	if err != nil {
		fmt.Println("ERR", err)
		return
	}
	key, _, _, _, _ := ssh.ParseAuthorizedKey([]byte("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHiojgVRI/bzT9/KdnJv9QzVjj6cRUQldIZUq76+c0ib"))
	host := strings.Repeat("a", 4*n)
	err = cb(host+":22", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 22}, key)
	fmt.Printf("kh_star n=%d match=%v\n", n, err == nil)
}

type sshSigWire struct {
	Version       uint32
	PublicKey     []byte
	Namespace     string
	Reserved      []byte
	HashAlgorithm string
	Signature     []byte
}

type sshSigSigned struct {
	Namespace     string
	Reserved      []byte
	HashAlgorithm string
	Hash          []byte
}

// verifySshSig mirrors bench/go/main.go parseAndVerifySshSig (x/crypto/ssh has no SSHSIG API).
func verifySshSig(armored string, msg []byte) bool {
	lines := strings.Split(strings.TrimSpace(armored), "\n")
	if len(lines) < 3 {
		return false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.Join(lines[1:len(lines)-1], ""))
	if err != nil || len(raw) < 6 || string(raw[:6]) != "SSHSIG" {
		return false
	}
	var w sshSigWire
	if ssh.Unmarshal(raw[6:], &w) != nil || w.Version != 1 || w.Namespace != "git" {
		return false
	}
	pk, err := ssh.ParsePublicKey(w.PublicKey)
	if err != nil {
		return false
	}
	var sig ssh.Signature
	if ssh.Unmarshal(w.Signature, &sig) != nil {
		return false
	}
	var digest []byte
	switch w.HashAlgorithm {
	case "sha256":
		d := sha256.Sum256(msg)
		digest = d[:]
	case "sha512":
		d := sha512.Sum512(msg)
		digest = d[:]
	default:
		return false
	}
	signed := append([]byte("SSHSIG"), ssh.Marshal(sshSigSigned{w.Namespace, w.Reserved, w.HashAlgorithm, digest})...)
	return pk.Verify(signed, &sig) == nil
}

func main() {
	if len(os.Args) >= 5 && os.Args[1] == "bench_sshsig" {
		armored, _ := os.ReadFile(os.Args[2])
		msg, _ := os.ReadFile(os.Args[3])
		n, _ := strconv.Atoi(os.Args[4])
		ok := 0
		for i := 0; i < n; i++ {
			if verifySshSig(string(armored), msg) {
				ok++
			}
		}
		fmt.Printf("ok=%d/%d\n", ok, n)
		return
	}
	if len(os.Args) >= 4 && os.Args[1] == "dos" && os.Args[2] == "kh_star" {
		n, _ := strconv.Atoi(os.Args[3])
		dosKhStar(n)
		return
	}
	if len(os.Args) < 3 || os.Args[1] != "vectors" {
		fmt.Fprintln(os.Stderr, "usage: oracle_go vectors <corpus.tsv>")
		os.Exit(2)
	}
	f, err := os.Open(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	for sc.Scan() {
		fields := strings.SplitN(sc.Text(), "\t", 4)
		if len(fields) < 3 {
			continue
		}
		data, _ := hex.DecodeString(fields[2])
		arg := ""
		if len(fields) == 4 {
			arg = fields[3]
		}
		fmt.Fprintf(out, "%s\t%s\n", fields[0], runOne(fields[1], data, arg))
	}
}
