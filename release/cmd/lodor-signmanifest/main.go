// lodor-signmanifest — detached-sign versions.json with the OFFLINE ed25519
// update-signing key so devices can verify the manifest's origin, not just its
// contents' hashes (security HIGH finding #4). It reads the PKCS8 PEM private
// key by PATH (never embedded in the repo, like the Android keystore), signs
// the manifest bytes verbatim, and writes base64(signature) to <manifest>.sig.
//
// The signature it produces is exactly what engine/update.VerifyManifestSig
// accepts: ed25519 over the raw manifest bytes, base64-std-encoded.
//
// Usage:
//
//	lodor-signmanifest <versions.json> [private-key.pem]
//
// Key source precedence:
//  1. the second positional arg, if given
//  2. $LODOR_UPDATE_SIGNING_KEY
//  3. /mnt/user/appdata/lodor/update-signing-ed25519.key (the release host path)
//
// Output: <versions.json>.sig (base64 of the 64-byte signature, no newline).
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"os"
)

const defaultKeyPath = "/mnt/user/appdata/lodor/update-signing-ed25519.key"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "lodor-signmanifest: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 1 || len(args) > 2 {
		return fmt.Errorf("usage: lodor-signmanifest <versions.json> [private-key.pem]")
	}
	manifestPath := args[0]
	keyPath := defaultKeyPath
	if len(args) == 2 && args[1] != "" {
		keyPath = args[1]
	} else if env := os.Getenv("LODOR_UPDATE_SIGNING_KEY"); env != "" {
		keyPath = env
	}

	priv, err := loadPrivateKey(keyPath)
	if err != nil {
		return err
	}
	manifest, err := os.ReadFile(manifestPath)
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}

	sig := ed25519.Sign(priv, manifest)
	sigB64 := base64.StdEncoding.EncodeToString(sig)

	outPath := manifestPath + ".sig"
	if err := os.WriteFile(outPath, []byte(sigB64), 0o644); err != nil {
		return fmt.Errorf("write signature: %w", err)
	}
	// Deliberately do NOT print the key or its path body — only the output file
	// and the public-key-safe fact that signing succeeded.
	fmt.Printf("signed %s -> %s (%d-byte ed25519 sig)\n", manifestPath, outPath, len(sig))
	return nil
}

// loadPrivateKey reads a PEM PKCS8 ed25519 private key from path and returns it.
// It refuses anything that isn't an ed25519 key so a wrong-algorithm keystore
// can't silently produce signatures the engine will never accept.
func loadPrivateKey(path string) (ed25519.PrivateKey, error) {
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read signing key %q: %w", path, err)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, fmt.Errorf("signing key %q is not PEM", path)
	}
	keyAny, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse PKCS8 signing key: %w", err)
	}
	priv, ok := keyAny.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("signing key is %T, want ed25519.PrivateKey", keyAny)
	}
	return priv, nil
}
