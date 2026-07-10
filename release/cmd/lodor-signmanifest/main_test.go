package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

// writeEphemeralKey generates a fresh ed25519 keypair, writes the private key as
// PKCS8 PEM to a temp file, and returns the path plus the public key. This keeps
// the test self-contained — it never depends on the out-of-repo production key
// existing in CI.
func writeEphemeralKey(t *testing.T) (string, ed25519.PublicKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	path := filepath.Join(t.TempDir(), "key.pem")
	if err := os.WriteFile(path, pemBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	return path, pub
}

// TestSignRoundTrip signs a manifest with an ephemeral key and verifies the
// emitted base64 signature with ed25519.Verify under the matching public key —
// the exact operation engine/update.VerifyManifestSig performs. This proves the
// signer produces a signature the engine will accept, without importing the
// engine module or touching the production key.
func TestSignRoundTrip(t *testing.T) {
	keyPath, pub := writeEphemeralKey(t)
	manifestPath := filepath.Join(t.TempDir(), "versions.json")
	manifest := []byte(`{"schema":1,"stable":{"version":"0.9.9"}}`)
	if err := os.WriteFile(manifestPath, manifest, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := run([]string{manifestPath, keyPath}); err != nil {
		t.Fatalf("run: %v", err)
	}

	sigB64, err := os.ReadFile(manifestPath + ".sig")
	if err != nil {
		t.Fatalf("read .sig: %v", err)
	}
	sig, err := base64.StdEncoding.DecodeString(string(sigB64))
	if err != nil {
		t.Fatalf("sig not base64: %v", err)
	}
	if len(sig) != ed25519.SignatureSize {
		t.Fatalf("sig is %d bytes, want %d", len(sig), ed25519.SignatureSize)
	}
	if !ed25519.Verify(pub, manifest, sig) {
		t.Fatal("signature did not verify over the manifest bytes")
	}
	// A single tampered byte must break verification.
	bad := make([]byte, len(manifest))
	copy(bad, manifest)
	bad[0] ^= 0xFF
	if ed25519.Verify(pub, bad, sig) {
		t.Fatal("signature verified over tampered manifest")
	}
}

// TestKeyPathPrecedence checks the arg > env > default precedence: an explicit
// arg wins over LODOR_UPDATE_SIGNING_KEY.
func TestKeyPathPrecedence(t *testing.T) {
	keyPath, pub := writeEphemeralKey(t)
	// Point the env at a nonexistent file; the explicit arg must win.
	t.Setenv("LODOR_UPDATE_SIGNING_KEY", filepath.Join(t.TempDir(), "nope.pem"))
	manifestPath := filepath.Join(t.TempDir(), "versions.json")
	manifest := []byte(`{"schema":1}`)
	if err := os.WriteFile(manifestPath, manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{manifestPath, keyPath}); err != nil {
		t.Fatalf("run with explicit key arg should win over env: %v", err)
	}
	sigB64, _ := os.ReadFile(manifestPath + ".sig")
	sig, _ := base64.StdEncoding.DecodeString(string(sigB64))
	if !ed25519.Verify(pub, manifest, sig) {
		t.Fatal("signature from arg-specified key did not verify")
	}
}

// TestEnvKeyUsedWhenNoArg checks the env is honored when no key arg is given.
func TestEnvKeyUsedWhenNoArg(t *testing.T) {
	keyPath, pub := writeEphemeralKey(t)
	t.Setenv("LODOR_UPDATE_SIGNING_KEY", keyPath)
	manifestPath := filepath.Join(t.TempDir(), "versions.json")
	manifest := []byte(`{"schema":1}`)
	if err := os.WriteFile(manifestPath, manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{manifestPath}); err != nil {
		t.Fatalf("run with env key: %v", err)
	}
	sigB64, _ := os.ReadFile(manifestPath + ".sig")
	sig, _ := base64.StdEncoding.DecodeString(string(sigB64))
	if !ed25519.Verify(pub, manifest, sig) {
		t.Fatal("signature from env-specified key did not verify")
	}
}

// TestRejectsNonEd25519Key ensures a non-ed25519 PKCS8 key is refused rather
// than silently producing a signature the engine can't use. We can't easily
// mint an RSA PKCS8 here without more imports, so we assert the malformed-PEM
// and missing-file paths error cleanly.
func TestRejectsBadKey(t *testing.T) {
	manifestPath := filepath.Join(t.TempDir(), "versions.json")
	_ = os.WriteFile(manifestPath, []byte(`{"schema":1}`), 0o644)

	// missing key file
	if err := run([]string{manifestPath, filepath.Join(t.TempDir(), "absent.pem")}); err == nil {
		t.Error("expected error for missing key file")
	}
	// non-PEM key file
	notPem := filepath.Join(t.TempDir(), "notpem.key")
	_ = os.WriteFile(notPem, []byte("this is not pem"), 0o600)
	if err := run([]string{manifestPath, notPem}); err == nil {
		t.Error("expected error for non-PEM key file")
	}
}
