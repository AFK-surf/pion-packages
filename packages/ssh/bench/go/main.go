package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

const (
	akLine0 = `restrict,command="/usr/bin/git-shell -c \"git-upload-pack 'repo'\"",from="10.0.0.0/8,192.168.1.*",no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHiojgVRI/bzT9/KdnJv9QzVjj6cRUQldIZUq76+c0ib alice@pion.dev`
	akLine1 = `cert-authority,principals="alice,deploy" ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ5Vkt3rF98orgYpBgu1VeYbkpFn+JxK3kLrGdcgIkbW4FuOgOMruOUrOCSG5gRz3wNx8/f1OR6oH7VAC0rEecE= bob@pion.dev`
	akLine2 = `restrict,from="192.0.2.0/24" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDb+mwhNZ4Fw1XcXQwRAi3yPDOFOO9lvKgeo/2kkk0YX2Y38p3hiygbbCOkIlUvouUkkSQKIJ8aJ5djaV/DU+aMTCXFQg5vt3ujtAffooJOfcLsFqwQ04dFAWOJPZQ2bj4uEsqnrFkdE7lgHaU/tFf/P854L8Iw/mmg8c80W+X/aBVNnIMqsYNy0HU3lUWKkmijhene0qg2pSZlEQ579XE78hEEmkP4LGUBLw74ZipbXbWAEoBEd+IeVCx7OA6wss8z5vXvv8bGUW0SVOEV2v2S0I3iqEsNop9dr+pkk+fiIkQX/cDFUln8rJdwMPTzXWUObFEoVHsS0IwY0VvZmT+B carol@pion.dev`

	khHashedText = "|1|zP5Wl+PoTJSeV9cix6XxaqulQ7M=|YnLSroYfQzHTHxXKM4KAkUi7ZNw= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHiojgVRI/bzT9/KdnJv9QzVjj6cRUQldIZUq76+c0ib alice@pion.dev\n" +
		"|1|PMPIYQ5YLxw3fRIAFQ6NbUaW4Is=|bOJwh25t84NL1ELNSbtjk7IgRuU= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ5Vkt3rF98orgYpBgu1VeYbkpFn+JxK3kLrGdcgIkbW4FuOgOMruOUrOCSG5gRz3wNx8/f1OR6oH7VAC0rEecE= bob@pion.dev\n"

	caEd25519Pub   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBp7Jq67dwdZ0voEX708CVgPQflZQuO31qAs0FKyvEdo ca-ed25519@pion.dev"
	aliceCertLine  = "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIMrey1YUxL+dDpXdMt2ad+/Ypr80dl8uTPDkDRsgOy3hAAAAIHiojgVRI/bzT9/KdnJv9QzVjj6cRUQldIZUq76+c0ibAAAAAAAAACoAAAABAAAADWFsaWNlLWNlcnQtMDEAAAATAAAABWFsaWNlAAAABmRlcGxveQAAAABpVTpwAAAAAHDbWfAAAABRAAAADWZvcmNlLWNvbW1hbmQAAAAWAAAAEi91c3IvYmluL2dpdC1zaGVsbAAAAA5zb3VyY2UtYWRkcmVzcwAAABAAAAAMMTkyLjAuMi4wLzI0AAAAKAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAAAAAAAMwAAAAtzc2gtZWQyNTUxOQAAACAaeyauu3cHWdL6BF+9PAlYD0H5WULjt9agLNBSsrxHaAAAAFMAAAALc3NoLWVkMjU1MTkAAABAXw5H4EYq0jubSBllJdcLqgbj/46DhQj/8/ZPx8bch9cDdjRC2k1GCkZ20SDesWiHaLkFQjXZopMg0Ij+2hk1DQ== alice@pion.dev"
	sshsigMsg      = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor Alice <alice@pion.dev> 1795425279 +0000\n\nfeat(ssh): initial commit\n"
	sshsigEd25519  = "-----BEGIN SSH SIGNATURE-----\n" +
		"U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgeKiOBVEj9vNP38p2cm/1DNWOPp\n" +
		"xFRCV0hlSrvr5zSJsAAAADZ2l0AAAAAAAAAAZzaGE1MTIAAABTAAAAC3NzaC1lZDI1NTE5\n" +
		"AAAAQNSkOF9ZsHasFNO6oD0y5+h0VkiVplRnFH8Vwj0H91m15i/aCUUzqelK/6vIIutxFk\n" +
		"8CpMb4ePdGj7lh/sJSnAQ=\n" +
		"-----END SSH SIGNATURE-----\n"
)

func fnv1aBytes(h uint64, b []byte) uint64 {
	for _, c := range b {
		h = (h ^ uint64(c)) * 1099511628211
	}
	return h
}

func runW1() {
	lines := [][]byte{[]byte(akLine0), []byte(akLine1), []byte(akLine2)}
	var hash uint64 = 14695981039346656037
	optTotal := 0
	lastFp := ""
	for i := 0; i < 20000; i++ {
		pk, _, opts, _, err := ssh.ParseAuthorizedKey(lines[i%3])
		if err != nil {
			fmt.Println("FAIL:w1", err)
			os.Exit(1)
		}
		optTotal += len(opts)
		fp := ssh.FingerprintSHA256(pk)
		hash = fnv1aBytes(hash, []byte(fp))
		lastFp = fp
	}
	fmt.Println("mode=w1")
	fmt.Println("count=20000")
	fmt.Printf("opt_total=%d\n", optTotal)
	fmt.Printf("last_fp=%s\n", lastFp)
	fmt.Printf("hash=%d\n", hash)
}

func matchHashedHost(pattern, hostname string) bool {
	if !strings.HasPrefix(pattern, "|1|") {
		return pattern == hostname
	}
	rest := pattern[3:]
	sep := strings.IndexByte(rest, '|')
	if sep <= 0 || sep+1 >= len(rest) {
		return false
	}
	salt, err := base64.StdEncoding.DecodeString(rest[:sep])
	if err != nil || len(salt) != 20 {
		return false
	}
	expected, err := base64.StdEncoding.DecodeString(rest[sep+1:])
	if err != nil || len(expected) != 20 {
		return false
	}
	mac := hmac.New(sha1.New, salt)
	mac.Write([]byte(hostname))
	return subtle.ConstantTimeCompare(mac.Sum(nil), expected) == 1
}

func runW2() {
	caPk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(caEd25519Pub))
	if err != nil {
		fmt.Println("FAIL:w2_ca", err)
		os.Exit(1)
	}
	caWire := caPk.Marshal()
	checker := &ssh.CertChecker{
		SupportedCriticalOptions: []string{"force-command", "source-address"},
		IsUserAuthority: func(auth ssh.PublicKey) bool {
			return bytes.Equal(auth.Marshal(), caWire)
		},
		Clock: func() time.Time {
			return time.Unix(1800000000, 0)
		},
	}

	khHits := 0
	var hash uint64 = 14695981039346656037
	khBytes := []byte(khHashedText)
	targets := []string{"github.com", "[git.example.com]:2222", "other.example.com"}
	for i := 0; i < 5000; i++ {
		rest := khBytes
		var hostLists [][]string
		for len(rest) > 0 {
			_, hosts, _, _, next, err := ssh.ParseKnownHosts(rest)
			if err != nil {
				fmt.Println("FAIL:w2_kh", err)
				os.Exit(1)
			}
			hostLists = append(hostLists, hosts)
			rest = next
		}
		for _, t := range targets {
			for _, hs := range hostLists {
				for _, h := range hs {
					if matchHashedHost(h, t) {
						khHits++
						break
					}
				}
			}
		}
	}

	certOk := 0
	var serialSum uint64
	certBytes := []byte(aliceCertLine)
	for j := 0; j < 1000; j++ {
		pk, _, _, _, err := ssh.ParseAuthorizedKey(certBytes)
		if err != nil {
			fmt.Println("FAIL:w2_cert_parse", err)
			os.Exit(1)
		}
		cert, ok := pk.(*ssh.Certificate)
		if !ok {
			fmt.Println("FAIL:w2_not_cert")
			os.Exit(1)
		}
		if err := checker.CheckCert("alice", cert); err != nil {
			fmt.Println("FAIL:w2_cert_verify", err)
			os.Exit(1)
		}
		certOk++
		serialSum += cert.Serial
		hash = fnv1aBytes(hash, []byte(cert.KeyId))
	}

	fmt.Println("mode=w2")
	fmt.Printf("kh_hits=%d\n", khHits)
	fmt.Printf("cert_ok=%d\n", certOk)
	fmt.Printf("serial_sum=%d\n", serialSum)
	fmt.Printf("hash=%d\n", hash)
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

func parseAndVerifySshSig(armored, expectedNs string, msg []byte) (string, error) {
	lines := strings.Split(strings.TrimSpace(armored), "\n")
	if len(lines) < 3 || lines[0] != "-----BEGIN SSH SIGNATURE-----" || lines[len(lines)-1] != "-----END SSH SIGNATURE-----" {
		return "", fmt.Errorf("bad armor")
	}
	raw, err := base64.StdEncoding.DecodeString(strings.Join(lines[1:len(lines)-1], ""))
	if err != nil || len(raw) < 6 || string(raw[:6]) != "SSHSIG" {
		return "", fmt.Errorf("bad magic")
	}
	var w sshSigWire
	if err := ssh.Unmarshal(raw[6:], &w); err != nil {
		return "", err
	}
	if w.Version != 1 || w.Namespace != expectedNs {
		return "", fmt.Errorf("bad version/ns")
	}
	pk, err := ssh.ParsePublicKey(w.PublicKey)
	if err != nil {
		return "", err
	}
	var sig ssh.Signature
	if err := ssh.Unmarshal(w.Signature, &sig); err != nil {
		return "", err
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
		return "", fmt.Errorf("bad hash alg")
	}
	signed := append([]byte("SSHSIG"), ssh.Marshal(sshSigSigned{
		Namespace:     w.Namespace,
		Reserved:      w.Reserved,
		HashAlgorithm: w.HashAlgorithm,
		Hash:          digest,
	})...)
	if err := pk.Verify(signed, &sig); err != nil {
		return "", err
	}
	return w.Namespace, nil
}

func encodeBinaryPacket(payload []byte) []byte {
	plen := len(payload)
	base := 5 + plen
	padLen := 8 - (base % 8)
	if padLen < 4 {
		padLen += 8
	}
	pktLen := 1 + plen + padLen
	out := make([]byte, 4+pktLen)
	binary.BigEndian.PutUint32(out[0:4], uint32(pktLen))
	out[4] = byte(padLen)
	copy(out[5:], payload)
	return out
}

func decodeBinaryPacket(data []byte) ([]byte, int, error) {
	if len(data) < 5 {
		return nil, 0, fmt.Errorf("eof")
	}
	pktLen := int(binary.BigEndian.Uint32(data[0:4]))
	total := 4 + pktLen
	if len(data) < total {
		return nil, 0, fmt.Errorf("eof")
	}
	padLen := int(data[4])
	if padLen < 4 || padLen >= pktLen {
		return nil, 0, fmt.Errorf("bad pad")
	}
	return data[5 : 5+pktLen-1-padLen], total, nil
}

func runW3() {
	msg := []byte(sshsigMsg)
	sigOk := 0
	var hash uint64 = 14695981039346656037
	for i := 0; i < 1000; i++ {
		ns, err := parseAndVerifySshSig(sshsigEd25519, "git", msg)
		if err != nil {
			fmt.Println("FAIL:w3_sshsig", err)
			os.Exit(1)
		}
		sigOk++
		hash = fnv1aBytes(hash, []byte(ns))
	}

	payload := []byte("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	pktBytesTotal := 0
	for j := 0; j < 50000; j++ {
		enc := encodeBinaryPacket(payload)
		dec, consumed, err := decodeBinaryPacket(enc)
		if err != nil {
			fmt.Println("FAIL:w3_pkt", err)
			os.Exit(1)
		}
		pktBytesTotal += consumed
		hash = fnv1aBytes(hash, dec)
	}

	fmt.Println("mode=w3")
	fmt.Printf("sig_ok=%d\n", sigOk)
	fmt.Printf("pkt_bytes=%d\n", pktBytesTotal)
	fmt.Printf("hash=%d\n", hash)
}

func main() {
	mode := "w1"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	switch mode {
	case "w1":
		runW1()
	case "w2":
		runW2()
	case "w3":
		runW3()
	default:
		fmt.Println("usage: ssh_bench_go [w1|w2|w3]")
		os.Exit(1)
	}
}
