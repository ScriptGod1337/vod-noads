#!/usr/bin/env python3
"""Decrypt APKM files (APKMirror encrypted bundles) to ZIP/APKS format.
Based on the open-source unapkm by souramoo (https://github.com/souramoo/unapkm).
Uses libsodium SecretStream (ChaCha20-Poly1305) with Argon2i key derivation."""

import sys
import struct
from pathlib import Path

try:
    import nacl.bindings as nb
except ImportError:
    sys.exit("pip install pynacl")


PASSPHRASE = b"#$%@#dfas4d00fFSDF9GSD56$^53$%7WRGF3dzzqasD!@"


def decrypt_apkm(input_path: str, output_path: str):
    with open(input_path, "rb") as f:
        data = f.read()

    offset = 0
    # Skip first byte
    offset += 1
    # Algorithm identifier (1 or 2)
    algo = data[offset]
    offset += 1
    print(f"Algorithm: {algo}")

    # ops_limit (8 bytes LE)
    ops_limit = struct.unpack_from("<Q", data, offset)[0]
    offset += 8
    print(f"Ops limit: {ops_limit}")

    # mem_limit (8 bytes LE)
    mem_limit = struct.unpack_from("<Q", data, offset)[0]
    offset += 8
    print(f"Mem limit: {mem_limit}")

    # chunk_size (8 bytes LE)
    chunk_size = struct.unpack_from("<Q", data, offset)[0]
    offset += 8
    print(f"Chunk size: {chunk_size}")

    # salt (16 bytes)
    salt = data[offset:offset + 16]
    offset += 16
    print(f"Salt: {salt.hex()}")

    # pw_hash_bytes / header for secretstream (24 bytes)
    stream_header = data[offset:offset + 24]
    offset += 24
    print(f"Stream header: {stream_header.hex()}")

    # NOTE: outputHash is COMPUTED from cryptoPwHash, not read from file!
    # Total header = 1+1+8+8+8+16+24 = 66 bytes

    # Derive key from passphrase using Argon2
    print("Deriving key with Argon2i (this may take a moment)...")
    if algo == 1:
        argon_algo = nb.crypto_pwhash_ALG_ARGON2I13
    else:
        argon_algo = nb.crypto_pwhash_ALG_ARGON2ID13

    key = nb.crypto_pwhash.crypto_pwhash_alg(
        outlen=32,
        passwd=PASSPHRASE,
        salt=salt,
        opslimit=ops_limit,
        memlimit=mem_limit,
        alg=argon_algo,
    )
    print(f"Derived key: {key.hex()}")

    # Initialize SecretStream
    state = nb.crypto_secretstream_xchacha20poly1305_state()
    nb.crypto_secretstream_xchacha20poly1305_init_pull(state, stream_header, key)

    # Decrypt chunks
    encrypted_data = data[offset:]
    print(f"Encrypted data size: {len(encrypted_data)} bytes")

    # The abytes (authentication tag overhead) for xchacha20poly1305
    ABYTES = nb.crypto_secretstream_xchacha20poly1305_ABYTES  # 17

    decrypted = bytearray()
    pos = 0
    chunk_num = 0
    enc_chunk_size = chunk_size + ABYTES

    while pos < len(encrypted_data):
        end = min(pos + enc_chunk_size, len(encrypted_data))
        chunk = encrypted_data[pos:end]
        pos = end

        msg, tag = nb.crypto_secretstream_xchacha20poly1305_pull(state, chunk)
        decrypted.extend(msg)
        chunk_num += 1

        if chunk_num % 100 == 0:
            print(f"  Decrypted {chunk_num} chunks ({len(decrypted)} bytes)...")

        if tag == nb.crypto_secretstream_xchacha20poly1305_TAG_FINAL:
            break

    print(f"Total decrypted: {len(decrypted)} bytes in {chunk_num} chunks")

    with open(output_path, "wb") as f:
        f.write(decrypted)

    # Verify it's a ZIP
    if decrypted[:2] == b'PK':
        print(f"SUCCESS: Output is a valid ZIP file -> {output_path}")
    else:
        print(f"WARNING: Output doesn't start with PK signature (got {decrypted[:4].hex()})")
        print(f"Written to {output_path} anyway")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.apkm> <output.apks>")
        sys.exit(1)
    decrypt_apkm(sys.argv[1], sys.argv[2])
